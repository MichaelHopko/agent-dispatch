"""End-to-end plugin replay with an in-memory Linear endpoint and a deterministic worker."""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("linear_plugin", ROOT / "plugins/linear/linear.py")
linear = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(linear)

TARGET = {"id": "fd12169e-812a-4526-a7da-6fe42a7c1339", "key": "TEST",
          "states": {"nodes": [{"id": "closed", "name": "Done", "type": "completed"}]}}
FINDING = {"key": "incident-4/verify", "title": "Verify returned price",
           "body": "Check the actual receipt before finishing.", "evidence": "session 4, turn 3"}


class LinearTest(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory()
        self.addCleanup(t.cleanup)
        self.path = Path(t.name)
        self.job = self.path / "job"
        self.job.mkdir()
        self.verifier = self.path / "verify"
        self.verifier.write_text('#!/bin/sh\ntest -s "$1/result" && echo "verified evidence"\n')
        self.verifier.chmod(0o755)
        env = patch.dict(os.environ, {"XDG_STATE_HOME": str(self.path), "MANAGER_LINEAR_SCOPE": "test",
                                      "MANAGER_TICKET_VERIFY": str(self.verifier)})
        env.start()
        self.addCleanup(env.stop)
        self.issues = {}
        self.comments = {}
        self.fail_update_once = True
        api = patch.object(linear, "graphql", self.graphql)
        api.start()
        self.addCleanup(api.stop)

    def graphql(self, query, variables):
        data = variables.get("input", {})
        if "issueCreate(" in query:
            self.assertNotIn(data["id"], self.issues)
            issue = dict(data, identifier=f"TEST-{len(self.issues)+1}", team={"id":TARGET["id"]}, archivedAt=None, state={"type":"unstarted"})
            self.issues[data["id"]] = issue
            return {"issueCreate": {"success": True, "issue": issue}}
        if "commentCreate(" in query:
            self.assertNotIn(data["id"], self.comments)
            self.comments[data["id"]] = dict(data, issue={"id":data["issueId"]})
            return {"commentCreate": {"success": True}}
        if "issueUpdate(" in query:
            if self.fail_update_once:
                self.fail_update_once = False
                raise OSError("simulated outage")
            self.issues[variables["id"]]["state"] = {"type":"completed"}
            return {"issueUpdate": {"success": True}}
        if "searchIssues(" in query:
            return {"searchIssues":{"nodes":list(self.issues.values())}}
        if "comment(id:" in query:
            return {"comment":self.comments.get(variables["id"])}
        if "issue(id:" in query:
            return {"issue":self.issues.get(variables["id"])}
        self.fail(query)

    def test_review_queue_verify_and_replay(self):
        with linear.registry(TARGET["id"]) as db:
            self.assertEqual(linear.intake(db, TARGET, FINDING), "TEST-1")
            self.assertEqual(linear.intake(db, TARGET, FINDING), "TEST-1")
            linear.claim(db, TARGET, self.job)
            self.assertEqual((self.job / "id").read_text(), "TEST-1")
            self.assertIn(FINDING["body"], (self.job / "goal").read_text())
            linear.claim(db, TARGET, self.path)
            self.assertFalse((self.path / "id").exists())
            (self.job / "result").write_text("fake worker's output")
            with self.assertRaises(OSError):
                linear.finish(db, TARGET, self.job, "complete")
            linear.finish(db, TARGET, self.job, "complete")
            self.assertEqual(len(self.issues), 1)
            self.assertEqual(len(self.comments), 1)
            self.assertEqual(next(iter(self.issues.values()))["state"]["type"], "completed")
            self.assertEqual(db.execute("select status from findings").fetchone()[0], "done")
            with patch.object(linear, "decision", return_value="TEST-1"):
                linear.intake(db, TARGET, dict(FINDING, key="later", evidence="new evidence"))
            self.assertEqual(len(self.issues), 1)
            self.assertEqual(len(self.comments), 2)

    def test_queue_is_scoped_to_workspace_and_team(self):
        with linear.registry(TARGET["id"]) as db:
            linear.intake(db, TARGET, FINDING)
        with patch.dict(os.environ, {"MANAGER_LINEAR_SCOPE": "second-workspace"}):
            with linear.registry(TARGET["id"]) as db:
                linear.claim(db, TARGET, self.job)
                self.assertFalse((self.job / "id").exists())
        with linear.registry("fd12169e-812a-4526-a7da-6fe42a7c1338") as db:
            linear.claim(db, TARGET, self.job)
            self.assertFalse((self.job / "id").exists())

    def test_unrelated_workspace_configuration_refused(self):
        with patch.dict(os.environ, {"MANAGER_LINEAR_SCOPE": "", "MANAGER_LEARNINGS_WORKSPACE": "/a",
                                     "MANAGER_TICKET_WORKSPACE": "/b"}):
            with self.assertRaisesRegex(ValueError, "one workspace"):
                with linear.registry(TARGET["id"]):
                    self.fail("mismatched workspace was accepted")

    def test_failed_verification_keeps_issue_open(self):
        with linear.registry(TARGET["id"]) as db:
            linear.intake(db, TARGET, FINDING)
            linear.claim(db, TARGET, self.job)
            with self.assertRaisesRegex(RuntimeError, "verifier"):
                linear.finish(db, TARGET, self.job, "complete")
            self.assertEqual(db.execute("select status from findings").fetchone()[0], "failed")
            self.assertFalse(self.comments)

    def test_plugins_work_together_through_their_entry_points(self):
        work = self.path / "workspace"
        work.mkdir()
        model = self.path / "model"
        model.write_text(
            "#!/usr/bin/env python3\nimport json,os,sys\n"
            "assert 'LINEAR_API_KEY' not in os.environ\ngoal=sys.stdin.read()\n"
            f"if 'Review session evidence' in goal: print(json.dumps({{'reviewed':True,'summary':'reviewed','findings':[{FINDING!r}]}}))\n"
            "else: print('verified work product')\n"
        )
        model.chmod(0o755)
        sink = self.path / "intake"
        fake_db = self.path / "linear.json"
        sink.write_text(f'''#!/usr/bin/env python3
import json,runpy
from pathlib import Path
test=runpy.run_path({str(Path(__file__).resolve())!r})
case=test['LinearTest']()
path=Path({str(fake_db)!r})
case.issues,case.comments=json.loads(path.read_text()) if path.exists() else ({{}},{{}})
case.fail_update_once=False
def graphql(query,variables):
    if 'teams(' in query:
        return {{'teams':{{'nodes':[test['TARGET']]}}}}
    result=case.graphql(query,variables)
    path.write_text(json.dumps([case.issues,case.comments]))
    return result
test['linear'].graphql=graphql
test['linear'].main()
''')
        sink.chmod(0o755)
        env = dict(os.environ, MANAGER_LINEAR_TEAM="TEST", LINEAR_API_KEY="test-only",
                   MANAGER_CLI=str(model), MANAGER_LEARNINGS_WORKSPACE=str(work),
                   MANAGER_LEARNINGS_EVIDENCE=str(work), MANAGER_LEARNINGS_INTAKE=str(sink),
                   MANAGER_TICKET_QUEUE=str(sink), MANAGER_TICKET_WORKSPACE=str(work))
        for path in ("daily-learnings", "ticket-worker", "daily-learnings", "ticket-worker"):
            subprocess.run([ROOT / "plugins" / path / "run"], env=env, capture_output=True, check=True)
        issues, comments = json.loads(fake_db.read_text())
        self.assertEqual(len(issues), 1)
        self.assertEqual(next(iter(issues.values()))["state"]["type"], "completed")
        self.assertEqual([item["body"] for item in comments.values()], ["verified evidence"])

    def test_review_retries_original_findings_after_outage(self):
        work = self.path / "work"
        work.mkdir()
        data = json.dumps({"reviewed": True, "summary": "reviewed", "findings":[FINDING]})
        calls = self.path / "calls"
        model = self.path / "model"
        model.write_text(f"#!/bin/sh\ncat >/dev/null\necho called >> '{calls}'\ncat <<'EOF'\n{data}\nEOF\n")
        model.chmod(0o755)
        sink = self.path / "intake"
        sink.write_text("#!/bin/sh\nexit 1\n")
        sink.chmod(0o755)
        env = dict(os.environ, MANAGER_CLI=str(model), MANAGER_LEARNINGS_WORKSPACE=str(work),
                   MANAGER_LEARNINGS_EVIDENCE=str(work), MANAGER_LEARNINGS_INTAKE=str(sink))
        review = ROOT / "plugins/daily-learnings/run"
        self.assertNotEqual(subprocess.run([review], env=env, capture_output=True).returncode, 0)
        sink.write_text(f'''#!/bin/sh
test "$1" = intake && cp "$2" '{work / "delivered"}'
''')
        subprocess.run([review], env=env, capture_output=True, check=True)
        self.assertEqual(calls.read_text().splitlines(), ["called"])
        self.assertEqual(json.loads((work / "delivered").read_text()), [FINDING])


if __name__ == "__main__":
    unittest.main()

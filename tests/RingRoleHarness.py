#!/usr/bin/env python3
"""Exercise the real ring helper with a stateful fake az; never contacts Azure."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SUB = "00000000-0000-0000-0000-000000000001"
PRINCIPAL = "00000000-0000-0000-0000-000000000002"
SCOPE = f"/subscriptions/{SUB}/resourceGroups/test-ring"
ROLE_ID = f"/subscriptions/{SUB}/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000003"
ASSIGNMENT_ID = f"{SCOPE}/providers/Microsoft.Authorization/roleAssignments/00000000-0000-0000-0000-000000000004"
ROLE = {
    "id": ROLE_ID,
    "roleName": "Azure Storage Smart Tier Remediator",
    "assignableScopes": [SCOPE],
}
ASSIGNMENT = {"id": ASSIGNMENT_ID, "principalId": PRINCIPAL,
              "roleDefinitionId": ROLE_ID, "scope": SCOPE}

MOCK_AZ = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
path = Path(os.environ["RING_MOCK_STATE"])
state = json.loads(path.read_text())
args = sys.argv[1:]
state["calls"].append(args)
path.write_text(json.dumps(state))
def option(name):
    return args[args.index(name) + 1]
def fail(message):
    print(message, file=sys.stderr)
    sys.exit(17)
if option("--subscription") != os.environ["RING_MOCK_SUB"]:
    fail("wrong subscription")
if "--all" in args and "--scope" in args:
    fail("Azure CLI rejects --all with --scope")
op = args[:3]
flags = state.get("flags", [])
if op == ["role", "definition", "list"]:
    if "--scope" not in args:
        fail("RG-only operator must list definitions at the ring scope")
    if "role_read_fail" in flags:
        fail("role read denied")
    if "malformed_role" in flags:
        print("{}")
    else:
        print(json.dumps(state["roles"]))
elif op == ["role", "assignment", "list"]:
    reads = sum(c[:3] == op for c in state["calls"])
    if "assignment_read_fail" in flags or ("verify_read_fail" in flags and reads > 1):
        fail("assignment read denied")
    print(json.dumps(state["assignments"]))
elif op == ["role", "assignment", "delete"]:
    if "delete_fail" in flags:
        fail("assignment delete denied")
    target = option("--ids")
    if "sticky_assignment" not in flags:
        state["assignments"] = [a for a in state["assignments"] if a["id"] != target]
elif op == ["role", "definition", "delete"]:
    if "definition_delete_fail" in flags:
        fail("definition delete denied")
    if option("--name") != state["roles"][0]["id"].rsplit("/", 1)[-1]:
        fail("definition deletion requires the GUID, not the full ARM id")
    state["roles"] = []
else:
    fail("unexpected command: " + repr(args))
path.write_text(json.dumps(state))
'''


class RingRoleHarness(unittest.TestCase):
    def run_helper(self, *, roles=None, assignments=None, flags=(), action="revoke"):
        with tempfile.TemporaryDirectory(prefix="ring-role-test-") as directory:
            task_dir = Path(directory)
            executable = task_dir / "az"
            executable.write_text(MOCK_AZ)
            executable.chmod(0o755)
            state_path = task_dir / "state.json"
            state_path.write_text(json.dumps({
                "roles": [ROLE] if roles is None else roles,
                "assignments": [ASSIGNMENT] if assignments is None else assignments,
                "flags": flags, "calls": [],
            }))
            env = dict(os.environ, PATH=f"{task_dir}{os.pathsep}{os.environ['PATH']}",
                       RING_MOCK_STATE=str(state_path), RING_MOCK_SUB=SUB)
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/ring-role.sh"), action, SUB, "test-ring", PRINCIPAL],
                env=env, text=True, capture_output=True, timeout=10,
            )
            return result, json.loads(state_path.read_text())

    def assert_no_definition_delete(self, state):
        self.assertFalse(any(c[:3] == ["role", "definition", "delete"] for c in state["calls"]))
        self.assertEqual(state["roles"], [ROLE])

    def test_success_deletes_exact_assignment_and_definition_then_verifies(self):
        result, state = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["roles"], [])
        self.assertEqual(state["assignments"], [])
        self.assertIn("Verified:", result.stdout)
        deletes = [c for c in state["calls"] if c[:3] == ["role", "assignment", "delete"]]
        self.assertEqual(len(deletes), 1)
        self.assertIn(ASSIGNMENT_ID, deletes[0])

    def test_assignment_delete_failure_preserves_definition(self):
        result, state = self.run_helper(flags=["delete_fail"])
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_definition_delete(state)
        self.assertEqual(state["assignments"], [ASSIGNMENT])
        self.assertIn("assignment delete denied", result.stderr)

    def test_still_present_assignment_is_not_success(self):
        result, state = self.run_helper(flags=["sticky_assignment"])
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_definition_delete(state)

    def test_read_failures_stop_without_definition_delete(self):
        for flag in ["role_read_fail", "assignment_read_fail", "verify_read_fail", "malformed_role"]:
            with self.subTest(flag=flag):
                result, state = self.run_helper(flags=[flag])
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_definition_delete(state)

    def test_absent_role_performs_no_deletion(self):
        result, state = self.run_helper(roles=[], assignments=[])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[2] == "delete" for c in state["calls"]))

    def test_absent_assignment_removes_unused_definition(self):
        result, state = self.run_helper(assignments=[])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["roles"], [])
        self.assertFalse(any(c[:3] == ["role", "assignment", "delete"] for c in state["calls"]))

    def test_shared_assignment_retains_definition(self):
        other = dict(ASSIGNMENT, principalId="another-principal", id=ASSIGNMENT_ID + "-other")
        result, state = self.run_helper(assignments=[ASSIGNMENT, other])
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_definition_delete(state)
        self.assertEqual(state["assignments"], [other])

    def test_conflicting_scope_is_never_reused_or_deleted(self):
        for action in ["grant", "revoke"]:
            for scopes in [[f"/subscriptions/{SUB}"], [SCOPE, SCOPE + "-other"]]:
                with self.subTest(action=action, scopes=scopes):
                    role = dict(ROLE, assignableScopes=scopes)
                    result, state = self.run_helper(roles=[role], action=action)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(state["roles"], [role])
                    self.assertFalse(any(c[2] in ["create", "delete"] for c in state["calls"]))

    def test_definition_delete_failure_is_not_success(self):
        result, state = self.run_helper(flags=["definition_delete_fail"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["roles"], [ROLE])
        self.assertNotIn("Verified:", result.stdout)

    def test_assignable_scope_comparison_is_case_insensitive(self):
        result, state = self.run_helper(roles=[dict(ROLE, assignableScopes=[SCOPE.upper()])])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["roles"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)

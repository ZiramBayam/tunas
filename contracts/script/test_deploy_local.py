import unittest
from unittest.mock import Mock, patch

from deploy_local import ForkError, encode_constructor, mine_hook, verify_runtime


class DeploymentBytecodeTest(unittest.TestCase):
    def test_appends_abi_encoded_addresses(self):
        init_code = encode_constructor("0xab", "0x" + "12" * 20, "0x" + "34" * 20)
        self.assertEqual(init_code, "0xab" + "0" * 24 + "12" * 20 + "0" * 24 + "34" * 20)

    def test_accounts_for_compiler_immutable_slots(self):
        runtime = {"object": "0xa10000d4", "immutableReferences": {"4": [{"start": 1, "length": 2}]}}
        verify_runtime("hook", "0xa1b2c3d4", runtime)

    def test_rejects_runtime_changes_outside_immutable_slots(self):
        runtime = {"object": "0xa10000d4", "immutableReferences": {"4": [{"start": 1, "length": 2}]}}
        with self.assertRaisesRegex(ForkError, "hook runtime"):
            verify_runtime("hook", "0xa1b2c3ff", runtime)

    def test_rejects_truncated_runtime(self):
        runtime = {"object": "0xa10000d4", "immutableReferences": {"4": [{"start": 1, "length": 2}]}}
        with self.assertRaisesRegex(ForkError, "hook runtime"):
            verify_runtime("hook", "0xa1", runtime)

    def test_reads_the_miner_stdout_pair(self):
        address = "0x" + "1" * 36 + "2a88"
        salt = "0x" + "2" * 64
        rpc = Mock()
        rpc.call.return_value = "0x" + "0" * 24 + address[2:]
        with patch("deploy_local.cast", side_effect=[f"{address}\t{salt}", address]):
            self.assertEqual(mine_hook(rpc, "0x" + "3" * 40, "0x" + "4" * 64), (address, salt))

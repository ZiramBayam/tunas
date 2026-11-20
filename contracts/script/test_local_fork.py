import unittest
from unittest.mock import Mock

from local_fork import BLOCK_HASH, CHAIN_ID, FORK_BLOCK, EXTERNAL, ForkError, verify_fork


class ForkGuardTest(unittest.TestCase):
    def setUp(self):
        self.rpc = Mock()
        answers = {
            "eth_chainId": hex(CHAIN_ID),
            "anvil_nodeInfo": {"forkConfig": {"forkBlockNumber": FORK_BLOCK, "forkChainId": 1}},
            "eth_getBlockByNumber": {"hash": BLOCK_HASH},
        }
        self.rpc.call.side_effect = lambda method, *args: answers[method]
        self.rpc.code_hash.side_effect = lambda address, *_: next(
            digest for target, digest in EXTERNAL.values() if target == address
        )
        self.answers = answers

    def test_accepts_pinned_anvil_fork(self):
        verify_fork(self.rpc)

    def test_rejects_wrong_chain_before_reading_contracts(self):
        self.answers["eth_chainId"] = "0x1"
        with self.assertRaisesRegex(ForkError, "chain ID"):
            verify_fork(self.rpc)
        self.rpc.code_hash.assert_not_called()

    def test_rejects_anvil_without_fork(self):
        self.answers["anvil_nodeInfo"] = {"forkConfig": {}}
        with self.assertRaisesRegex(ForkError, "pinned Ethereum fork"):
            verify_fork(self.rpc)
        self.rpc.code_hash.assert_not_called()

    def test_rejects_wrong_block_hash(self):
        self.answers["eth_getBlockByNumber"] = {"hash": "0x" + "0" * 64}
        with self.assertRaisesRegex(ForkError, "block hash"):
            verify_fork(self.rpc)
        self.rpc.code_hash.assert_not_called()

    def test_rejects_changed_canonical_code(self):
        self.rpc.code_hash.side_effect = None
        self.rpc.code_hash.return_value = "0x" + "0" * 64
        with self.assertRaisesRegex(ForkError, "queue runtime"):
            verify_fork(self.rpc)

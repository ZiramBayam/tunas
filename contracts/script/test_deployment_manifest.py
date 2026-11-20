import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from deployment_manifest import publish


class ManifestTest(unittest.TestCase):
    def test_publishes_deployment_identity_and_matching_abi(self):
        artifact = {
            "metadata": {
                "compiler": {"version": "0.8.36+commit.8a079791"},
                "settings": {
                    "optimizer": {"enabled": True, "runs": 200},
                    "evmVersion": "cancun",
                    "compilationTarget": {"src/TunasHook.sol": "TunasHook"},
                },
                "sources": {"src/TunasHook.sol": {"keccak256": "0x1234"}},
            },
            "abi": [{"type": "function", "name": "cash"}],
        }
        factory = {
            "transactionHash": "0x" + "1" * 64,
            "blockHash": "0x" + "2" * 64,
            "blockNumber": "0x1933b64",
            "gasUsed": "0x100",
            "status": "0x1",
        }
        hook = {**factory, "transactionHash": "0x" + "3" * 64, "blockNumber": "0x1933b65"}
        deployed = {
            "contracts": {"hook": "0x" + "1" * 40},
            "roles": {"capitalOwner": "0x" + "2" * 40},
            "codeHashes": {"hook": "0x" + "3" * 64},
            "factoryReceipt": factory,
            "hookReceipt": hook,
            "create2": {"flags": "0x2a88"},
        }
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            path = publish(directory, "http://127.0.0.1:8545", deployed, {"hook": artifact}, "source-commit")
            manifest = json.loads(path.read_bytes())
            exported = (directory / manifest["build"]["abis"]["hook"]["file"]).read_bytes()
            self.assertEqual(json.loads(exported), artifact["abi"])
            self.assertEqual(manifest["build"]["abis"]["hook"]["sha256"], hashlib.sha256(exported).hexdigest())
            self.assertEqual(manifest["deploymentId"], hook["transactionHash"])
            self.assertEqual(manifest["deploymentBlockHash"], factory["blockHash"])
            self.assertEqual(manifest["deploymentBlockNumber"], str(int(factory["blockNumber"], 16)))
            self.assertEqual(manifest["receipts"], [])

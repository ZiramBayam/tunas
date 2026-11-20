import hashlib
import json
import tempfile
from pathlib import Path

from local_fork import BLOCK_HASH, CHAIN_ID, FORK_BLOCK, UPSTREAM_CHAIN_ID


def write_atomic(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as file:
        file.write(payload)
        pending = Path(file.name)
    try:
        pending.replace(path)
    finally:
        pending.unlink(missing_ok=True)


def json_bytes(data):
    return (json.dumps(data, indent=2, sort_keys=True) + "\n").encode()


def receipt_summary(receipt):
    return {
        "hash": receipt["transactionHash"],
        "blockNumber": str(int(receipt["blockNumber"], 16)),
        "blockHash": receipt["blockHash"],
        "gasUsed": str(int(receipt["gasUsed"], 16)),
        "status": int(receipt["status"], 16),
    }


def publish(directory, rpc_url, deployment, artifacts, source_commit):
    sources = {}
    abis = {}
    artifact_hashes = {}
    for key, artifact in artifacts.items():
        metadata = artifact["metadata"]
        sources.update({name: value["keccak256"] for name, value in metadata["sources"].items()})
        name = next(iter(metadata["settings"]["compilationTarget"].values()))
        encoded = json_bytes(artifact["abi"])
        digest = hashlib.sha256(encoded).hexdigest()
        relative_path = f"abi/{name}.{digest}.json"
        write_atomic(directory / relative_path, encoded)
        abis[key] = {"file": relative_path, "sha256": digest}
        artifact_hashes[key] = hashlib.sha256(json_bytes(artifact)).hexdigest()

    factory_tx = receipt_summary(deployment["factoryReceipt"])
    hook_tx = receipt_summary(deployment["hookReceipt"])
    hook_metadata = artifacts["hook"]["metadata"]
    manifest = {
        "schemaVersion": 1,
        "environment": "local-fork",
        "deploymentId": hook_tx["hash"],
        "chainId": CHAIN_ID,
        "upstreamChainId": UPSTREAM_CHAIN_ID,
        "forkBlockNumber": str(FORK_BLOCK),
        "forkBlockHash": BLOCK_HASH,
        "rpcUrl": rpc_url,
        "deploymentBlockNumber": factory_tx["blockNumber"],
        "deploymentBlockHash": factory_tx["blockHash"],
        "contracts": deployment["contracts"],
        "codeHashes": deployment["codeHashes"],
        "roles": deployment["roles"],
        "receipts": [],
        "transactions": {"factory": factory_tx, "hook": hook_tx},
        "create2": deployment["create2"],
        "build": {
            "compiler": hook_metadata["compiler"]["version"],
            "evmVersion": hook_metadata["settings"]["evmVersion"],
            "optimizer": hook_metadata["settings"]["optimizer"],
            "sourceCommit": source_commit,
            "sourceHashes": sources,
            "dependencies": {"uniswapV4Core": "v4.0.0"},
            "artifactHashes": artifact_hashes,
            "abis": abis,
        },
    }
    path = directory / "local.json"
    write_atomic(path, json_bytes(manifest))
    return path

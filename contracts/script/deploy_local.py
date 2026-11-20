import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

from local_fork import EXTERNAL, ForkError, LocalRPC, verify_fork

CONTRACTS_DIR = Path(__file__).resolve().parents[1]
CONTRACT_NAMES = {"factory": "TunasFactory", "implementation": "TunasReceipt", "hook": "TunasHook"}
HOOK_MASK = 0x3FFF
HOOK_FLAGS = 0x2A88


def build_contracts(solc):
    command = ["forge", "build", "--root", str(CONTRACTS_DIR), "--skip", "test", "--quiet"]
    if solc:
        command += ["--use", solc]
    subprocess.run(command, check=True)
    return {
        key: json.loads((CONTRACTS_DIR / "out" / f"{name}.sol" / f"{name}.json").read_text())
        for key, name in CONTRACT_NAMES.items()
    }


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


def checksum(address):
    return cast("to-check-sum-address", address)


def encode_constructor(bytecode, *addresses):
    return bytecode + "".join(address[2:].lower().rjust(64, "0") for address in addresses)


def mine_hook(rpc, proxy, init_code_hash):
    output = cast(
        "create2", "--deployer", proxy, "--init-code-hash", init_code_hash,
        "--ends-with", f"{HOOK_FLAGS:04x}", "--threads", "2", "--color", "never",
    )
    mined = re.fullmatch(r"(0x[0-9a-fA-F]{40})\s+(0x[0-9a-fA-F]{64})", output)
    if not mined:
        raise ForkError("Unable to read mined CREATE2 address and salt")
    address, salt = mined.groups()
    expected = rpc.call("web3_sha3", "0xff" + proxy[2:] + salt[2:] + init_code_hash[2:])
    if address.lower() != "0x" + expected[-40:].lower() or int(address, 16) & HOOK_MASK != HOOK_FLAGS:
        raise ForkError("Unexpected mined hook address")
    return checksum(address), salt


def send_transaction(rpc, transaction):
    tx_hash = rpc.call("eth_sendTransaction", transaction)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        receipt = rpc.call("eth_getTransactionReceipt", tx_hash)
        if receipt:
            if receipt["status"] != "0x1":
                raise ForkError(f"Deployment reverted: {tx_hash}")
            return receipt
        time.sleep(0.2)
    raise ForkError(f"No deployment receipt yet: {tx_hash}")


def verify_runtime(name, code, bytecode):
    observed = bytearray.fromhex(code[2:])
    expected = bytes.fromhex(bytecode["object"][2:])
    if len(observed) == len(expected):
        for references in bytecode.get("immutableReferences", {}).values():
            for reference in references:
                start = reference["start"]
                end = start + reference["length"]
                observed[start:end] = expected[start:end]
        if observed == expected:
            return
    raise ForkError(f"Unexpected {name} runtime")


def read_address(rpc, address, selector):
    word = rpc.call("eth_call", {"to": address, "data": selector}, "latest")
    if len(word) != 66 or word[:26] != "0x" + "0" * 24:
        raise ForkError(f"Unexpected ABI response from {address}")
    return checksum("0x" + word[-40:])


def verify_contract(rpc, name, address, artifact, bindings):
    code = rpc.call("eth_getCode", address, "latest")
    verify_runtime(name, code, artifact["deployedBytecode"])
    for signature, expected in bindings.items():
        selector = "0x" + artifact["methodIdentifiers"][signature]
        if read_address(rpc, address, selector) != expected:
            raise ForkError(f"Unexpected {name} binding {signature}")
    return rpc.call("web3_sha3", code)


def deploy(rpc, solc):
    verify_fork(rpc)
    external = {name: address for name, (address, _) in EXTERNAL.items()}
    if read_address(rpc, external["quoter"], cast("sig", "poolManager()")) != external["poolManager"]:
        raise ForkError("Unexpected Quoter PoolManager")

    accounts = [checksum(account) for account in rpc.call("eth_accounts")[:3]]
    if len(set(accounts)) != 3:
        raise ForkError("Expected three distinct local accounts")
    capital, seller, curator = accounts
    artifacts = build_contracts(solc)

    nonce = rpc.call("eth_getTransactionCount", capital, "pending")
    factory = cast("compute-address", capital, "--nonce", str(int(nonce, 16)))
    hook_init_code = encode_constructor(
        artifacts["hook"]["bytecode"]["object"], external["poolManager"], factory, curator, capital
    )
    init_code_hash = rpc.call("web3_sha3", hook_init_code)
    proxy = external["create2Deployer"]
    hook, salt = mine_hook(rpc, proxy, init_code_hash)
    if rpc.code_hash(hook) is not None:
        raise ForkError(f"Mined hook address already in use: {hook}")

    factory_init_code = encode_constructor(
        artifacts["factory"]["bytecode"]["object"], external["queue"], external["weth"]
    )
    factory_tx = send_transaction(rpc, {"from": capital, "nonce": nonce, "data": factory_init_code})
    if checksum(factory_tx["contractAddress"]) != factory:
        raise ForkError("Factory deployed at an unexpected address")
    implementation_selector = "0x" + artifacts["factory"]["methodIdentifiers"]["implementation()"]
    implementation = read_address(rpc, factory, implementation_selector)
    factory_hash = verify_contract(rpc, "factory", factory, artifacts["factory"], {
        "queue()": external["queue"], "weth()": external["weth"], "implementation()": implementation,
    })
    receipt_hash = verify_contract(rpc, "implementation", implementation, artifacts["implementation"], {})

    hook_tx = send_transaction(rpc, {"from": capital, "to": proxy, "data": salt + hook_init_code[2:]})
    hook_hash = verify_contract(rpc, "hook", hook, artifacts["hook"], {
        "manager()": external["poolManager"], "factory()": factory, "weth()": external["weth"],
        "curator()": curator, "capitalOwner()": capital,
    })

    return {
        "contracts": {**external, "factory": factory, "implementation": implementation, "hook": hook},
        "codeHashes": {
            **{name: digest for name, (_, digest) in EXTERNAL.items()},
            "factory": factory_hash, "implementation": receipt_hash, "hook": hook_hash,
        },
        "roles": {"seller": seller, "curator": curator, "capitalOwner": capital},
        "factoryReceipt": factory_tx,
        "hookReceipt": hook_tx,
        "create2": {"deployer": proxy, "salt": salt, "initCodeHash": init_code_hash, "flags": hex(HOOK_FLAGS)},
    }


def main():
    parser = argparse.ArgumentParser(description="Deploy Tunas to the pinned local Anvil fork")
    parser.add_argument("--port", type=int, default=8545, help="Local Anvil port")
    parser.add_argument("--solc", help="Path to the pinned Solidity compiler")
    args = parser.parse_args()
    try:
        deployment = deploy(LocalRPC(args.port), args.solc)
    except (ForkError, OSError, subprocess.SubprocessError, ValueError) as error:
        sys.exit(str(error))
    print(json.dumps(deployment, indent=2))


if __name__ == "__main__":
    main()

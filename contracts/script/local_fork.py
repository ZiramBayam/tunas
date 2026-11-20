import json
from contextlib import closing
from http.client import HTTPConnection, HTTPException

CHAIN_ID = 31337
UPSTREAM_CHAIN_ID = 1
FORK_BLOCK = 26_426_211
BLOCK_HASH = "0xf88f6a3a9947fd7e8117bce1ae533286ba8d9c1f9b7ba88e62a0b789782157b7"

EXTERNAL = {
    "queue": (
        "0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1",
        "0x9bc25fa4b2f98d56db4aa4156a6dc98360ccd4ef9c7bc7f891797b0024272100",
    ),
    "stETH": (
        "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84",
        "0xb9c1c929064cd21734c102a698e68bf617feefcfa5a9f62407c45401546736bf",
    ),
    "weth": (
        "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        "0xd0a06b12ac47863b5c7be4185c2deaad1c61557033f56c7d4ea74429cbb25e23",
    ),
    "poolManager": (
        "0x000000000004444c5dc75cB358380D2e3dE08A90",
        "0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293",
    ),
    "router": (
        "0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af",
        "0x6a5f46971b50c6e1b7eef97902311444e479d734e4f80ad88367783cf373fe7f",
    ),
    "quoter": (
        "0x99bd42B2B22e531f283b7F8a86dFf631EB16A9D1",
        "0x6ea0b89e6ad804a982d971baa5dfbeaad9ecc5ecd5f45371bb88180111eccc5b",
    ),
    "permit2": (
        "0x000000000022D473030F116dDEE9F6B43aC78BA3",
        "0xc67d1657868aa5146eaf24fb879fb1fdec3d2d493b3683a61c9c2f4fb2851131",
    ),
    "create2Deployer": (
        "0x4e59b44847b379578588920cA78FbF26c0B4956C",
        "0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989",
    ),
}


class ForkError(RuntimeError):
    pass


class LocalRPC:
    def __init__(self, port=8545):
        if not 1 <= port <= 65535:
            raise ValueError("RPC port must be between 1 and 65535")
        self.port = port
        self.url = f"http://127.0.0.1:{port}"

    def call(self, method, *params):
        try:
            with closing(HTTPConnection("127.0.0.1", self.port, timeout=30)) as connection:
                body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1})
                connection.request("POST", "/", body, {"Content-Type": "application/json"})
                response = connection.getresponse()
                if response.status != 200:
                    raise ForkError(f"{method}: HTTP {response.status}")
                payload = json.load(response)
        except (OSError, HTTPException, ValueError) as error:
            raise ForkError(f"{method}: {error}") from error
        if "error" in payload:
            raise ForkError(f"{method}: {payload['error']['message']}")
        return payload["result"]

    def code_hash(self, address):
        code = self.call("eth_getCode", address, "latest")
        return self.call("web3_sha3", code) if code != "0x" else None


def verify_fork(rpc):
    if int(rpc.call("eth_chainId"), 16) != CHAIN_ID:
        raise ForkError(f"Expected local chain ID {CHAIN_ID}")
    fork = rpc.call("anvil_nodeInfo").get("forkConfig") or {}
    if fork.get("forkBlockNumber") != FORK_BLOCK or fork.get("forkChainId", UPSTREAM_CHAIN_ID) != UPSTREAM_CHAIN_ID:
        raise ForkError("Expected the pinned Ethereum fork")
    block = rpc.call("eth_getBlockByNumber", hex(FORK_BLOCK), False)
    if not block or block.get("hash") != BLOCK_HASH:
        raise ForkError("Unexpected fork block hash")
    for name, (address, digest) in EXTERNAL.items():
        if rpc.code_hash(address) != digest:
            raise ForkError(f"Unexpected {name} runtime at {address}")

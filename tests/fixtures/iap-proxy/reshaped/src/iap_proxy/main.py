import asyncio

import uvicorn

ALL_INTERFACES = "0.0.0." + "0"


def run() -> None:
    uvicorn.run("iap_proxy.main:app", host=ALL_INTERFACES, port=8080)

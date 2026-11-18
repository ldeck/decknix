import asyncio

import uvicorn


def run() -> None:
    uvicorn.run(
        "iap_proxy.main:app",
        host="0.0.0.0",
        port=8080,
        reload=False,
    )

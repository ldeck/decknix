import os

import uvicorn


def run() -> None:
    uvicorn.run("iap_proxy.main:app", host=os.getenv("IAP_PROXY_HOST", "127.0.0.1"), port=8080)

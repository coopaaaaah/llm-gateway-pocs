import json
import os

from fastapi import HTTPException
from litellm.integrations.custom_guardrail import CustomGuardrail

CANARY = os.environ.get("GUARDRAIL_CANARY", "GATEWAY-POC-GUARDRAIL-CANARY")


def _blocked(where: str) -> HTTPException:
    return HTTPException(status_code=400, detail={"error": f"guardrail: canary found in {where}"})


class CanaryGuardrail(CustomGuardrail):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        if CANARY in json.dumps(data.get("messages", []), default=str):
            raise _blocked("request")
        return data

    async def async_post_call_success_hook(self, data, user_api_key_dict, response):
        if CANARY in str(response):
            raise _blocked("response")
        return response

    async def async_post_call_streaming_iterator_hook(
        self, user_api_key_dict, response, request_data
    ):
        # Keep a tail so a canary split across two chunks is still caught.
        tail = ""
        async for chunk in response:
            for choice in getattr(chunk, "choices", None) or []:
                delta = getattr(choice, "delta", None)
                tail = (tail + (getattr(delta, "content", None) or ""))[-2 * len(CANARY) :]
            if CANARY in tail:
                raise _blocked("streamed response")
            yield chunk

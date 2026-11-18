// Canary guardrail for Bifrost OSS. Not yet compiled: see ../../README.md "Guardrail".
package main

import (
	"bytes"
	"errors"
	"os"

	"github.com/maximhq/bifrost/core/schemas"
)

var canary = []byte("GATEWAY-POC-GUARDRAIL-CANARY")

func Init(config any) error {
	if v := os.Getenv("GUARDRAIL_CANARY"); v != "" {
		canary = []byte(v)
	}
	return nil
}

func GetName() string {
	return "canary-guardrail"
}

func blocked(where string) *schemas.HTTPResponse {
	return &schemas.HTTPResponse{
		StatusCode: 400,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       []byte(`{"error":"guardrail: canary found in ` + where + `"}`),
	}
}

func HTTPTransportPreHook(ctx *schemas.BifrostContext, req *schemas.HTTPRequest) (*schemas.HTTPResponse, error) {
	if bytes.Contains(req.Body, canary) {
		return blocked("request"), nil
	}
	return nil, nil
}

func HTTPTransportPostHook(ctx *schemas.BifrostContext, req *schemas.HTTPRequest, resp *schemas.HTTPResponse) error {
	if bytes.Contains(resp.Body, canary) {
		*resp = *blocked("response")
	}
	return nil
}

func HTTPTransportResponseHeadersHook(ctx *schemas.BifrostContext, req *schemas.HTTPRequest, resp *schemas.HTTPResponseMetadata) error {
	return nil
}

// Chunk-level only: a canary split across two chunks slips through. Good enough to prove the hook.
func HTTPTransportStreamChunkHook(ctx *schemas.BifrostContext, req *schemas.HTTPRequest, chunk *schemas.BifrostStreamChunk) (*schemas.BifrostStreamChunk, error) {
	if chunk == nil || chunk.BifrostChatResponse == nil {
		return chunk, nil
	}
	for _, choice := range chunk.BifrostChatResponse.Choices {
		if choice.ChatStreamResponseChoice != nil && choice.ChatStreamResponseChoice.Delta != nil {
			if c := choice.ChatStreamResponseChoice.Delta.Content; c != nil && bytes.Contains([]byte(*c), canary) {
				return nil, errors.New("guardrail: canary found in streamed response")
			}
		}
	}
	return chunk, nil
}

func PreRequestHook(ctx *schemas.BifrostContext, req *schemas.BifrostRequest) error {
	return nil
}

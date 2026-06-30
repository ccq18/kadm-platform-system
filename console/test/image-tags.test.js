import test from "node:test";
import assert from "node:assert/strict";
import { extractImageTag, formatTimestampImageTag, resolveImageTag } from "../src/image-tags.js";

test("formats timestamp image tags as YYYYMMDDHHMMSS", () => {
  assert.equal(formatTimestampImageTag(new Date(2026, 5, 30, 9, 8, 7)), "20260630090807");
});

test("uses a timestamp tag when no explicit image tag is provided", () => {
  const tag = resolveImageTag("", () => new Date(2026, 5, 30, 9, 8, 7));

  assert.equal(tag, "20260630090807");
});

test("keeps an explicit image tag after trimming whitespace", () => {
  const tag = resolveImageTag("  release_20260630  ", () => new Date(2026, 5, 30, 9, 8, 7));

  assert.equal(tag, "release_20260630");
});

test("extracts the tag from a configured repository image", () => {
  assert.equal(
    extractImageTag("ghcr.io/ccq18/demo-hello:20260630090807@sha256:abc", "ghcr.io/ccq18/demo-hello"),
    "20260630090807"
  );
});

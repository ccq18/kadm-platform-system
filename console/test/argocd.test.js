import test from "node:test";
import assert from "node:assert/strict";
import { ArgoCdClient, buildApplicationRequest, buildSyncRequest } from "../src/argocd.js";

test("builds an Argo CD application status request", () => {
  const request = buildApplicationRequest({
    baseUrl: "https://argocd.example.com/",
    token: "argocd-token",
    application: "demo-hello",
    insecureTLS: true
  });

  assert.equal(request.url, "https://argocd.example.com/api/v1/applications/demo-hello");
  assert.equal(request.method, "GET");
  assert.equal(request.headers.Authorization, "Bearer argocd-token");
  assert.equal(request.insecureTLS, true);
});

test("builds an Argo CD sync request", () => {
  const request = buildSyncRequest({
    baseUrl: "https://argocd.example.com",
    token: "argocd-token",
    application: "demo-hello",
    revision: "main"
  });

  assert.equal(request.url, "https://argocd.example.com/api/v1/applications/demo-hello/sync");
  assert.equal(request.method, "POST");
  assert.deepEqual(JSON.parse(request.body), {
    revision: "main",
    prune: true,
    dryRun: false
  });
});

test("syncApplication uses the GitOps revision instead of the source repo revision", async () => {
  const calls = [];
  const client = new ArgoCdClient({
    baseUrl: "https://argocd.example.com",
    token: "argocd-token",
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      return { ok: true, status: 200, text: async () => "{}" };
    }
  });

  await client.syncApplication({
    github: { ref: "source-feature" },
    gitops: { ref: "gitops-prod" },
    argocd: { application: "demo-hello" }
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(JSON.parse(calls[0].options.body), {
    revision: "gitops-prod",
    prune: true,
    dryRun: false
  });
});

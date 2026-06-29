import { joinUrl, jsonHeaders, sendJsonRequest } from "./request.js";

const GITHUB_API_BASE = "https://api.github.com";

export function buildWorkflowDispatchRequest({ token, owner, repo, workflow, ref, inputs = {} }) {
  return {
    url: joinUrl(
      GITHUB_API_BASE,
      `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/actions/workflows/${encodeURIComponent(workflow)}/dispatches`
    ),
    method: "POST",
    headers: jsonHeaders(token, {
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28"
    }),
    body: JSON.stringify({ ref, inputs })
  };
}

export function buildWorkflowRunsRequest({ token, owner, repo, workflow, branch, limit = 10 }) {
  const params = new URLSearchParams({
    per_page: String(limit)
  });
  if (branch) {
    params.set("branch", branch);
  }

  return {
    url: joinUrl(
      GITHUB_API_BASE,
      `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/actions/workflows/${encodeURIComponent(workflow)}/runs?${params.toString()}`
    ),
    method: "GET",
    headers: jsonHeaders(token, {
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28"
    })
  };
}

export function buildGitHubContentRequest({ token, owner, repo, path, ref }) {
  const params = new URLSearchParams();
  if (ref) {
    params.set("ref", ref);
  }

  return {
    url: joinUrl(
      GITHUB_API_BASE,
      `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/contents/${encodeURIComponent(path)}${params.toString() ? `?${params}` : ""}`
    ),
    method: "GET",
    headers: jsonHeaders(token, {
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28"
    })
  };
}

export function buildGitHubContentUpdateRequest({ token, owner, repo, path, branch, sha, message, content }) {
  return {
    url: joinUrl(
      GITHUB_API_BASE,
      `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/contents/${encodeURIComponent(path)}`
    ),
    method: "PUT",
    headers: jsonHeaders(token, {
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28"
    }),
    body: JSON.stringify({
      message,
      content: Buffer.from(content).toString("base64"),
      sha,
      branch
    })
  };
}

export function updateKustomizeImageTag(content, tag, imageName = null) {
  const lines = content.split("\n");
  let activeImageMatches = !imageName;
  let updated = false;

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const imageEntry = line.match(/^(\s*-\s*name:\s*)(\S+)\s*$/);
    if (imageEntry) {
      activeImageMatches = !imageName || imageEntry[2] === imageName;
      continue;
    }

    const newNameEntry = line.match(/^(\s*newName:\s*)(\S+)\s*$/);
    if (newNameEntry && imageName && newNameEntry[2] === imageName) {
      activeImageMatches = true;
      continue;
    }

    const tagEntry = line.match(/^(\s*newTag:\s*).+$/);
    if (tagEntry && activeImageMatches && !updated) {
      lines[index] = `${tagEntry[1]}${tag}`;
      updated = true;
    }
  }

  if (!updated) {
    throw new Error(
      imageName
        ? `kustomize image tag was not found for image: ${imageName}`
        : "kustomize image tag was not found"
    );
  }

  return lines.join("\n");
}

export class GitHubClient {
  constructor({ token, fetchImpl }) {
    this.token = token;
    this.fetchImpl = fetchImpl;
  }

  async dispatchWorkflow(app, { imageTag } = {}) {
    const inputs = {};
    if (imageTag) {
      inputs.image_tag = imageTag;
    }

    const request = buildWorkflowDispatchRequest({
      token: this.token,
      owner: app.github.owner,
      repo: app.github.repo,
      workflow: app.github.workflow,
      ref: app.github.ref,
      inputs
    });

    await sendJsonRequest(request, this.fetchImpl);
    return { dispatched: true, ref: app.github.ref, inputs };
  }

  async listWorkflowRuns(app) {
    const request = buildWorkflowRunsRequest({
      token: this.token,
      owner: app.github.owner,
      repo: app.github.repo,
      workflow: app.github.workflow,
      branch: app.github.ref
    });

    const data = await sendJsonRequest(request, this.fetchImpl);
    return data.workflow_runs || [];
  }

  async updateGitOpsApp(app, imageTag) {
    const contentRequest = buildGitHubContentRequest({
      token: this.token,
      owner: app.gitops.owner,
      repo: app.gitops.repo,
      path: `${app.gitops.path}/kustomization.yaml`,
      ref: app.gitops.ref
    });
    const file = await sendJsonRequest(contentRequest, this.fetchImpl);
    const raw = Buffer.from(String(file.content || "").replace(/\n/g, ""), "base64").toString("utf8");
    const updated = updateKustomizeImageTag(raw, imageTag, app.gitops.image);

    const updateRequest = buildGitHubContentUpdateRequest({
      token: this.token,
      owner: app.gitops.owner,
      repo: app.gitops.repo,
      path: `${app.gitops.path}/kustomization.yaml`,
      branch: app.gitops.ref,
      sha: file.sha,
      message: `chore: release ${app.id} ${imageTag}`,
      content: updated
    });
    await sendJsonRequest(updateRequest, this.fetchImpl);
    return { updated: true, imageTag, path: `${app.gitops.path}/kustomization.yaml` };
  }
}

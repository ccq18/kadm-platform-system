import express from "express";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { normalizeAppsConfig } from "./config.js";
import { extractImageTag } from "./image-tags.js";
import { ReleaseManager } from "./release-manager.js";
import { createStaticAppRegistry, createStaticSourceProjectRegistry, publicProject } from "./projects.js";
import { deriveRolloutVersions, validateDeleteVersion, validatePromoteVersion, validateSwitchVersion } from "./versions.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export function createApp({ apps, appRegistry, sourceProjectRegistry, github, argocd, rollouts, releaseManager, cluster }) {
  const server = express();
  const releases = releaseManager || new ReleaseManager({ github, argocd, rollouts });
  const registry = appRegistry || createStaticAppRegistry(apps || []);
  const sourceRegistry = sourceProjectRegistry || createStaticSourceProjectRegistry(apps || []);

  server.use(express.json({ limit: "64kb" }));
  server.use(express.static(path.join(__dirname, "../public")));

  server.get("/api/apps", async (_req, res, next) => {
    try {
      res.json({ apps: (await registry.listApps()).map(publicApp) });
    } catch (error) {
      next(error);
    }
  });

  server.get("/api/projects", async (_req, res, next) => {
    try {
      res.json({ projects: (await registry.listApps()).map(publicProject) });
    } catch (error) {
      next(error);
    }
  });

  server.post("/api/projects", async (req, res, next) => {
    try {
      const project = await registry.createApp(req.body || {});
      res.status(201).json({ project: publicProject(project) });
    } catch (error) {
      next(error);
    }
  });

  server.get("/api/projects/source", async (_req, res, next) => {
    try {
      res.json({ projects: (await sourceRegistry.listApps()).map(publicProject) });
    } catch (error) {
      next(error);
    }
  });

  server.post("/api/projects/sync", async (_req, res, next) => {
    try {
      const source = await loadLatestProjectRegistry({ registry, sourceRegistry, github });
      if (source.origin === "github" && typeof sourceRegistry.replaceApps === "function") {
        await sourceRegistry.replaceApps(source.projects);
      }
      const result = await registry.reconcileApps(source.projects);
      res.json({
        result: {
          source: source.origin,
          revision: source.revision,
          warning: source.warning,
          synced: result.synced,
          deleted: result.deleted
        },
        projects: result.projects.map(publicProject)
      });
    } catch (error) {
      next(error);
    }
  });

  server.post("/api/projects/:id/sync", async (req, res, next) => {
    try {
      const sourceProject = await sourceRegistry.getApp(req.params.id);
      const project = await registry.syncApp(sourceProject);
      res.json({ project: publicProject(project) });
    } catch (error) {
      next(error);
    }
  });

  server.patch("/api/projects/:id", async (req, res, next) => {
    try {
      const project = await registry.updateApp(req.params.id, req.body || {});
      res.json({ project: publicProject(project) });
    } catch (error) {
      next(error);
    }
  });

  server.delete("/api/projects/:id", async (req, res, next) => {
    try {
      const result = await registry.deleteApp(req.params.id);
      res.json({ result });
    } catch (error) {
      next(error);
    }
  });

  server.get("/api/cluster", async (_req, res, next) => {
    try {
      ensureCluster(cluster);
      res.json(await cluster.getCluster());
    } catch (error) {
      next(error);
    }
  });

  server.post("/api/cluster/join-script", async (req, res, next) => {
    try {
      ensureCluster(cluster);
      const role = req.body?.role;
      if (!["master", "worker"].includes(role)) {
        const error = new Error(`Unsupported node role: ${role}`);
        error.status = 400;
        throw error;
      }
      res.json(cluster.generateJoinScript({ role }));
    } catch (error) {
      next(error);
    }
  });

  server.get("/api/apps/:id/status", async (req, res, next) => {
    try {
      const app = await registry.getApp(req.params.id);
      const [application, rollout, replicaSets, workflowRuns, diagnostics] = await Promise.allSettled([
        argocd.getApplication(app),
        rollouts.getRollout(app),
        loadReplicaSets(rollouts, app),
        github.listWorkflowRuns(app),
        loadDiagnostics(rollouts, app)
      ]);
      const rolloutValue = settledValue(rollout);
      const replicaSetsValue = settledValue(replicaSets, []);
      const diagnosticsValue = settledValue(diagnostics, emptyDiagnostics());

      res.json({
        app: publicApp(app),
        argocd: settledValue(application),
        rollout: rolloutValue,
        replicaSets: replicaSetsValue,
        workflowRuns: settledValue(workflowRuns, []),
        diagnostics: diagnosticsValue,
        releaseTask: releases.getTask(app.id),
        versions: rollout.status === "fulfilled"
          ? attachImageTagsToVersions(app, deriveRolloutVersions(rolloutValue, replicaSetsValue), replicaSetsValue)
          : []
      });
    } catch (error) {
      next(error);
    }
  });

  server.get("/api/apps/:id/versions", async (req, res, next) => {
    try {
      const app = await registry.getApp(req.params.id);
      const [rollout, replicaSets] = await Promise.all([
        rollouts.getRollout(app),
        loadReplicaSets(rollouts, app)
      ]);
      res.json({
        app: publicApp(app),
        versions: attachImageTagsToVersions(app, deriveRolloutVersions(rollout, replicaSets), replicaSets)
      });
    } catch (error) {
      next(error);
    }
  });

  server.delete("/api/apps/:id/versions/:hash", async (req, res, next) => {
    try {
      const app = await registry.getApp(req.params.id);
      const [rollout, replicaSets] = await Promise.all([
        rollouts.getRollout(app),
        loadReplicaSets(rollouts, app)
      ]);
      const version = validateDeleteVersion(deriveRolloutVersions(rollout, replicaSets), req.params.hash);
      const result = await rollouts.deleteReplicaSet(app, version.resourceName);
      res.status(202).json({ app: publicApp(app), version, result });
    } catch (error) {
      next(error);
    }
  });

  server.post("/api/apps/:id/versions/:hash/switch", async (req, res, next) => {
    try {
      const app = await registry.getApp(req.params.id);
      const [rollout, replicaSets] = await Promise.all([
        rollouts.getRollout(app),
        loadReplicaSets(rollouts, app)
      ]);
      const version = validateSwitchVersion(
        attachImageTagsToVersions(app, deriveRolloutVersions(rollout, replicaSets), replicaSets),
        req.params.hash
      );
      const result = version.role === "candidate"
        ? await rollouts.runAction(app, "promote")
        : await releaseRetainedVersionThroughGitOps({ app, version, replicaSets, github, argocd });
      res.status(202).json({ app: publicApp(app), version, result });
    } catch (error) {
      next(error);
    }
  });

  server.post("/api/apps/:id/release", async (req, res, next) => {
    try {
      const app = await registry.getApp(req.params.id);
      logActionRequest("release", app, req.body);
      const releaseTask = releases.start(app, {
        imageTag: req.body?.imageTag
      });
      res.status(202).json({ app: publicApp(app), releaseTask });
    } catch (error) {
      next(error);
    }
  });

  server.post("/api/apps/:id/release/cancel", async (req, res, next) => {
    try {
      const app = await registry.getApp(req.params.id);
      logActionRequest("release/cancel", app, req.body);
      const releaseTask = releases.cancel(app.id);
      res.status(202).json({ app: publicApp(app), releaseTask });
    } catch (error) {
      next(error);
    }
  });

  server.post("/api/apps/:id/build", async (req, res, next) => {
    try {
      const app = await registry.getApp(req.params.id);
      logActionRequest("build", app, req.body);
      const result = await github.dispatchWorkflow(app, {
        imageTag: req.body?.imageTag
      });
      res.status(202).json({ app: publicApp(app), result });
    } catch (error) {
      next(error);
    }
  });

  server.post("/api/apps/:id/sync", async (req, res, next) => {
    try {
      const app = await registry.getApp(req.params.id);
      logActionRequest("sync", app, req.body);
      const result = await argocd.syncApplication(app);
      res.status(202).json({ app: publicApp(app), result });
    } catch (error) {
      next(error);
    }
  });

  server.post("/api/apps/:id/promote", async (req, res, next) => {
    try {
      const app = await registry.getApp(req.params.id);
      logActionRequest("promote", app, req.body);
      if (req.body?.versionHash) {
        const rollout = await rollouts.getRollout(app);
        validatePromoteVersion(deriveRolloutVersions(rollout), req.body.versionHash);
      }
      const result = await rollouts.runAction(app, "promote");
      res.status(202).json({ app: publicApp(app), action: "promote", result });
    } catch (error) {
      next(error);
    }
  });

  server.post("/api/apps/:id/rollout/:action", async (req, res, next) => {
    try {
      const app = await registry.getApp(req.params.id);
      const action = req.params.action;
      logActionRequest(`rollout/${action}`, app, req.body);
      if (!["promote", "promote-full", "abort", "restart"].includes(action)) {
        res.status(400).json({ error: "Unsupported rollout action." });
        return;
      }
      const result = await rollouts.runAction(app, action);
      res.status(202).json({ app: publicApp(app), action, result });
    } catch (error) {
      next(error);
    }
  });

  server.use((req, res) => {
    if (req.path.startsWith("/api/")) {
      res.status(404).json({ error: "API endpoint not found." });
      return;
    }
    res.sendFile(path.join(__dirname, "../public/index.html"));
  });

  server.use((error, _req, res, _next) => {
    const status = error.status || 500;
    res.status(status).json({ error: error.message || "Internal server error." });
  });

  return server;
}

async function loadLatestProjectRegistry({ registry, sourceRegistry, github }) {
  const cachedProjects = await sourceRegistry.listApps();
  const effectiveProjects = await registry.listApps();
  const registrySource = inferRegistrySource(cachedProjects, effectiveProjects);

  if (registrySource && typeof github.readAppsRegistry === "function") {
    try {
      const gitRegistry = await github.readAppsRegistry(registrySource);
      return {
        origin: "github",
        projects: normalizeAppsConfig(gitRegistry.apps),
        revision: gitRegistry.revision || null
      };
    } catch (error) {
      if (!cachedProjects.length) {
        throw error;
      }
      return {
        origin: "source-cache",
        projects: cachedProjects,
        revision: null,
        warning: error.message
      };
    }
  }

  return {
    origin: "source-cache",
    projects: cachedProjects,
    revision: null
  };
}

function inferRegistrySource(cachedProjects, effectiveProjects) {
  const project = cachedProjects[0] || effectiveProjects[0] || null;
  if (!project?.gitops?.owner || !project?.gitops?.repo) {
    return null;
  }

  return {
    owner: project.gitops.owner,
    repo: project.gitops.repo,
    ref: project.gitops.ref || "main",
    path: "apps/apps.json"
  };
}

function publicApp(app) {
  return {
    id: app.id,
    name: app.name,
    github: {
      owner: app.github.owner,
      repo: app.github.repo,
      workflow: app.github.workflow,
      ref: app.github.ref
    },
    argocd: app.argocd,
    rollout: app.rollout
  };
}

function ensureCluster(cluster) {
  if (!cluster) {
    const error = new Error("Cluster API is not configured.");
    error.status = 503;
    throw error;
  }
}

async function loadReplicaSets(rollouts, app) {
  if (typeof rollouts.getReplicaSets !== "function") {
    return [];
  }
  return rollouts.getReplicaSets(app);
}

async function loadDiagnostics(rollouts, app) {
  if (typeof rollouts.getDiagnostics !== "function") {
    return emptyDiagnostics();
  }
  return rollouts.getDiagnostics(app);
}

function emptyDiagnostics() {
  return {
    summary: null,
    pods: [],
    events: [],
    logs: []
  };
}

function settledValue(result, fallback = null) {
  if (result.status === "fulfilled") {
    return result.value;
  }
  return { error: result.reason?.message || "request failed", fallback };
}

function logActionRequest(action, app, body) {
  console.log(
    JSON.stringify({
      type: "action-request",
      at: new Date().toISOString(),
      action,
      appId: app.id,
      body: body || {}
    })
  );
}

async function releaseRetainedVersionThroughGitOps({ app, version, replicaSets, github, argocd }) {
  const imageTag = imageTagForVersion(app, version, replicaSets);
  const gitops = await github.updateGitOpsApp(app, imageTag);
  const sync = await argocd.syncApplication(app);
  return { gitops, sync, imageTag };
}

function imageTagForVersion(app, version, replicaSets) {
  const replicaSet = replicaSets.find((candidate) => candidate.metadata?.name === version.resourceName);
  if (!replicaSet) {
    throwVersionError(`ReplicaSet not found for version: ${version.hash}`);
  }

  const image = configuredContainerImage(replicaSet, app.gitops.image);
  if (!image) {
    throwVersionError(`Configured image not found for version: ${version.hash}`);
  }

  const tag = extractImageTag(image, app.gitops.image);
  if (tag) {
    return tag;
  }

  throwVersionError(`Configured image does not contain a tag: ${image}`);
}

function configuredContainerImage(replicaSet, configuredImage) {
  const containers = replicaSet?.spec?.template?.spec?.containers || [];
  const container = containers.find((candidate) => imageMatchesRepository(candidate.image, configuredImage));
  return container?.image || null;
}

function imageMatchesRepository(image, repository) {
  return image === repository || image?.startsWith(`${repository}:`) || image?.startsWith(`${repository}@`);
}

function throwVersionError(message) {
  const error = new Error(message);
  error.status = 409;
  throw error;
}

function attachImageTagsToVersions(app, versions, replicaSets) {
  return versions.map((version) => ({
    ...version,
    imageTag: imageTagForVersionOrNull(app, version, replicaSets)
  }));
}

function imageTagForVersionOrNull(app, version, replicaSets) {
  try {
    return imageTagForVersion(app, version, replicaSets);
  } catch (_error) {
    return null;
  }
}

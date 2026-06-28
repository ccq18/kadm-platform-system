-- KADM uses Argo Rollouts for app delivery. Argo CD does not always infer
-- Rollout health correctly from this CRD, so we provide an explicit mapping.
hs = {}

if obj.status ~= nil then
  local phase = obj.status.phase
  local message = obj.status.message or phase or "Progressing"

  if phase == "Healthy" then
    hs.status = "Healthy"
    hs.message = message
    return hs
  end

  if phase == "Paused" then
    hs.status = "Suspended"
    hs.message = message
    return hs
  end

  if phase == "Degraded" then
    hs.status = "Degraded"
    hs.message = message
    return hs
  end

  hs.status = "Progressing"
  hs.message = message
  return hs
end

hs.status = "Progressing"
hs.message = "Waiting for rollout status"
return hs

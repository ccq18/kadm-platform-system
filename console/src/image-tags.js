const IMAGE_TAG_PATTERN = /^[A-Za-z0-9._-]+$/;

export function formatTimestampImageTag(date = new Date()) {
  return [
    date.getFullYear(),
    pad2(date.getMonth() + 1),
    pad2(date.getDate()),
    pad2(date.getHours()),
    pad2(date.getMinutes()),
    pad2(date.getSeconds())
  ].join("");
}

export function resolveImageTag(input, now = () => new Date()) {
  const tag = String(input || "").trim() || formatTimestampImageTag(now());
  validateImageTag(tag);
  return tag;
}

export function validateImageTag(tag) {
  if (!IMAGE_TAG_PATTERN.test(tag)) {
    const error = new Error("Image tag must contain only letters, numbers, dot, underscore, or dash.");
    error.status = 400;
    throw error;
  }
}

export function extractImageTag(image, repository) {
  if (!image || !repository || !image.startsWith(`${repository}:`)) {
    return null;
  }
  return image.slice(repository.length + 1).split("@")[0] || null;
}

function pad2(value) {
  return String(value).padStart(2, "0");
}

#!/usr/bin/env node

const MAX_REINJECTS = 3;

function decisionForBoardWake({ topic, agent, remainingTurns, hasNewPosts, reinjectCount }) {
  if (!topic || !agent || remainingTurns <= 0 || !hasNewPosts || reinjectCount >= MAX_REINJECTS) {
    return { decision: "approve" };
  }
  return {
    decision: "block",
    reason: `New posts on collab topic ${topic} - your turn ${MAX_REINJECTS - reinjectCount} wake available for ${agent}.`,
  };
}

async function main() {
  const raw = await readStdin();
  let payload = {};
  try {
    payload = raw ? JSON.parse(raw) : {};
  } catch {
    payload = {};
  }

  const result = decisionForBoardWake({
    topic: payload.topic || process.env.COLLAB_TOPIC_NAME,
    agent: payload.agent || process.env.COLLAB_AGENT,
    remainingTurns: Number(payload.remainingTurns ?? process.env.COLLAB_REMAINING_TURNS ?? 0),
    hasNewPosts: Boolean(payload.hasNewPosts ?? process.env.COLLAB_HAS_NEW_POSTS === "1"),
    reinjectCount: Number(payload.reinjectCount ?? process.env.COLLAB_REINJECT_COUNT ?? 0),
  });

  process.stdout.write(JSON.stringify(result));
}

function readStdin() {
  return new Promise((resolve) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      data += chunk;
    });
    process.stdin.on("end", () => resolve(data));
    if (process.stdin.isTTY) resolve("");
  });
}

if (require.main === module) {
  main().catch((error) => {
    process.stdout.write(JSON.stringify({ decision: "approve", reason: error.message }));
  });
}

module.exports = { MAX_REINJECTS, decisionForBoardWake };

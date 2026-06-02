/**
 * checks.ts — Project-local extension for flux.nvim
 *
 * Hooks every write tool call and runs:
 *   1. just format   (stylua auto-format)
 *   2. just lint     (lua-language-server check)
 *   3. just test     (if the written file is a test/spec file)
 *
 * Reports results via Pi notifications so failures are visible.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { exec } from "node:child_process";
import { resolve, relative } from "node:path";

/**
 * Run a shell command in the project root, returning stdout.
 * Throws on non-zero exit with stderr as the message.
 */
function runCommand(cwd: string, cmd: string): Promise<string> {
  return new Promise((resolve, reject) => {
    exec(cmd, { cwd, timeout: 60_000 }, (err, stdout, stderr) => {
      if (err) {
        reject(stderr || stdout || err.message || "unknown error");
      } else {
        resolve(stdout);
      }
    });
  });
}

/** True if the file path suggests a test/spec file, based on conventions in this project. */
function isTestFile(filePath: string): boolean {
  // Normalize path separators
  const normalized = filePath.replace(/\\/g, "/");
  return (
    normalized.includes("test") ||
    normalized.endsWith("_spec.lua") ||
    normalized.includes("/spec/") ||
    normalized.includes("/__tests__/")
  );
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_result", async (event, ctx) => {
    // Only react to write tool results
    if (event.toolName !== "write") return;

    const writePath = resolve(ctx.cwd, (event.input as { path: string }).path);
    const projectRoot = ctx.cwd;

    // Skip files outside the project
    if (!writePath.startsWith(projectRoot)) return;

    const relPath = relative(projectRoot, writePath);
    const isTest = isTestFile(writePath);
    const steps: string[] = [];

    // ── Step 1: just format ──────────────────────────────────────────
    try {
      await runCommand(projectRoot, "just format");
      steps.push("✅ format");
    } catch (err) {
      steps.push("❌ format");
      ctx.ui.notify(
        `just format failed after writing ${relPath}\n${String(err).slice(0, 300)}`,
        "error",
      );
      // Don't proceed to lint if format itself failed
      return;
    }

    // ── Step 2: just lint ────────────────────────────────────────────
    try {
      const lintOut = await runCommand(projectRoot, "just lint");
      steps.push("✅ lint");
      // lua-language-server sometimes reports issues via stdout even with exit 0
      if (lintOut.trim().length > 0) {
        ctx.ui.notify(
          `lint warnings for ${relPath}:\n${lintOut.slice(0, 300)}`,
          "warning",
        );
      }
    } catch (err) {
      steps.push("❌ lint");
      ctx.ui.notify(
        `just lint failed after writing ${relPath}\n${String(err).slice(0, 300)}`,
        "error",
      );
    }

    // ── Step 3 (conditional): just test ──────────────────────────────
    if (isTest) {
      try {
        await runCommand(projectRoot, "just test");
        steps.push("✅ test");
      } catch (err) {
        steps.push("❌ test");
        ctx.ui.notify(
          `just test failed after writing ${relPath}\n${String(err).slice(0, 300)}`,
          "error",
        );
      }
    }

    ctx.ui.notify(`wrote ${relPath} → ${steps.join(" · ")}`, "info");
  });
}

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  createHardenedResourceLoader,
  preflightPi,
  runPi,
} from "../scripts/agent/pi.mjs";

function fakeSdk() {
  const calls = { create: [], backendTool: [], runtime: [], manager: [] };
  let tool;
  const agent = {
    events: [],
    subscribe(handler) {
      this.events.push(handler);
    },
    async prompt(value) {
      this.promptValue = value;
      for (const handler of this.events) {
        handler({
          type: "message_update",
          assistantMessageEvent: { type: "text_delta", delta: "agent response" },
        });
      }
    },
  };
  const sdk = {
    calls,
    createBashToolDefinition(cwd, options) {
      calls.backendTool.push({ cwd, options });
      tool = {
        name: "bash",
        async execute(_id, params, signal, onUpdate) {
          return options.operations.exec(params.command, cwd, {
            signal,
            onData: onUpdate,
          });
        },
      };
      return tool;
    },
    ModelRuntime: {
      async create(options) {
        calls.runtime.push(options);
        return { kind: "dedicated-runtime" };
      },
    },
    SessionManager: {
      inMemory(cwd) {
        calls.manager.push(cwd);
        return { kind: "memory-session" };
      },
    },
    getModel(provider, model) {
      return { provider, id: model };
    },
    async createAgentSession(options) {
      calls.create.push(options);
      return { session: agent, extensionsResult: { extensions: [] } };
    },
  };
  return { sdk, calls, agent, getTool: () => tool };
}

test("hardened resource loader performs no host resource discovery", () => {
  const loader = createHardenedResourceLoader();
  assert.deepEqual(loader.getExtensions().extensions, []);
  assert.deepEqual(loader.getSkills().skills, []);
  assert.deepEqual(loader.getPrompts().prompts, []);
  assert.deepEqual(loader.getThemes().themes, []);
  assert.deepEqual(loader.getAgentsFiles().agentsFiles, []);
  assert.deepEqual(loader.getAppendSystemPrompt(), []);
  assert.match(loader.getSystemPrompt(), /hardened Squarebox agent session/);
});

test("Pi receives one backend-backed bash tool and no host tools", async () => {
  const { sdk, calls, agent } = fakeSdk();
  const executions = [];
  const backend = {
    async exec(argv, options) {
      executions.push({ argv, options });
      return { stdout: "inside guest\n", stderr: "", exitCode: 0 };
    },
  };
  const output = [];
  const result = await runPi({
    sdk,
    backend,
    workspace: "/host/worktree",
    agentDir: "/host/agent-config",
    provider: "openai",
    model: "test-model",
    prompt: "inspect the project",
    output: (value) => output.push(value),
  });

  assert.equal(agent.promptValue, "inspect the project");
  assert.equal(calls.create.length, 1);
  const createOptions = calls.create[0];
  assert.equal(createOptions.cwd, "/workspace");
  assert.equal(createOptions.noTools, "all");
  assert.equal(createOptions.customTools.length, 1);
  assert.deepEqual(calls.manager, ["/workspace"]);
  assert.deepEqual(calls.runtime, [
    { authPath: "/host/agent-config/auth.json", modelsPath: "/host/agent-config/models.json" },
  ]);
  assert.equal(calls.backendTool[0].cwd, "/workspace");
  assert.equal(calls.backendTool[0].options.exposeSessionEnvironment, false);
  assert.equal(result.backendWorkspace, "/workspace");

  await result.session;
  const tool = createOptions.customTools[0];
  const updates = [];
  await tool.execute("call-1", { command: "printf inside" }, undefined, (update) => {
    if (update) updates.push(update);
  });
  assert.deepEqual(executions, [
    {
      argv: ["/bin/bash", "-lc", "printf inside"],
      options: {
        cwd: "/workspace",
        stdin: undefined,
        signal: undefined,
        timeout: undefined,
      },
    },
  ]);
  assert.equal(updates.length, 1);
  assert.equal(updates[0].toString(), "inside guest\n");
  assert.deepEqual(output, ["agent response"]);
});

test("invalid backend fails before Pi session creation", async () => {
  const { sdk, calls } = fakeSdk();
  await assert.rejects(
    runPi({ sdk, backend: {}, workspace: "/host/worktree", agentDir: "/host/agent", prompt: "hello" }),
    /backend\.exec is required/,
  );
  assert.equal(calls.create.length, 0);
});

test("preflight checks the explicit SDK surface", async () => {
  const { sdk } = fakeSdk();
  assert.deepEqual(await preflightPi({ sdk }), {
    package: "@earendil-works/pi-coding-agent",
    ready: true,
  });
  await assert.rejects(
    preflightPi({ sdk: { createAgentSession() {}, SessionManager: {} } }),
    /bash tool factory/,
  );
});

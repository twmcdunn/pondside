grep -H '^description:' Sources/PondsideLexicon/Core/Skills/*/SKILL.md


4. Where to read the MCP skills
- Source of truth: Sources/PondsideLexicon/Core/Skills/<folder>/SKILL.md
- The synoptic description agents see is the first front-matter line:
grep -H '^description:' Sources/PondsideLexicon/Core/Skills/*/SKILL.md
- MCP list:
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"prompts/list"}' | .build/debug/pondside mcp
and resources/list for skill://... URIs.
- Server list/instructions: Sources/PondsideBridge/MCPServer.swift (guides, skills, instructions).
- What the app injects for a graphics request: AgentRun.graphicsPrompt in Sources/PondsideBridge/AgentRun.swift.
- Expected skill list test: Tests/PondsideBridgeTests/MCPTests.swift.

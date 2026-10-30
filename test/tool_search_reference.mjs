import { join } from "node:path";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const { Bm25Ranker, createToolSearchDocument, createToolSearchToolDefinition, tokenize } = await import(pathToFileURL(join(source, "packages/coding-agent/src/extensions/tool-search/tool.ts")));
const { rankDocuments } = await import(pathToFileURL(join(source, "packages/durable/src/search.ts")));
const specs = [
    { name: "alpha", description: "Alpha tool", exposure: "direct", parameters: { type: "object" } },
    { name: "github_get_issue", description: "Get a GitHub issue by number", exposure: "deferred", parameters: { type: "object", properties: { number: { type: "number", description: "Issue number" } } } },
    { name: "github_list_repos", description: "List the repositories of a user", exposure: "deferred", parameters: { type: "object" } },
    { name: "omega", description: "Omega tool", exposure: "direct", parameters: { type: "object" } },
];
let active = ["alpha", "omega", "tool_search"];
const api = { getAllTools: () => specs, getActiveTools: () => active, setActiveTools: next => { active = next; } };
const search = createToolSearchToolDefinition({ tools: api });
const searches = [{ query: "github issue", limit: 1 }, { query: "repositories", limit: 1 }, { query: "weather forecast" }, { query: "  " }, { query: "issue", limit: 0 }];
const offered = [], results = [];
for (const query of searches) {
    offered.push([...active]);
    try {
        const result = await search.execute("fixture", query);
        results.push(result.content[0].text);
    } catch (error) {
        results.push(`Error: ${error.message}`);
    }
}
offered.push([...active]);
const rankSpecs = [
    { name: "mcp__github__list_issues", description: "List issues in a repository.", parameters: { type: "object", properties: { state: { type: "string", description: "open or closed" } } } },
    { name: "mcp__github__create_pull_request", description: "Open a pull request.", parameters: { type: "object" } },
    { name: "mcp__linear__search_issues", description: "Search Linear issues by text.", parameters: { type: "object" } },
    { name: "mcp__app__queue_read", description: "Read a queued message of this thread.", parameters: { type: "object" } },
    { name: "mcp__dev-app__thread_read", description: "Read durable state and a paginated timeline from any thread.", parameters: { type: "object", properties: { filters: { items: { anyOf: [{ description: "Archived milestone" }] } } } }, namespace: { name: "mcp__dev-app", description: "Kubernetes cluster", instructions: "Discover team schedules" } },
    { name: "first_tie", description: "matching tokens", parameters: { type: "object" } },
    { name: "other_tie", description: "matching tokens", parameters: { type: "object" } },
];
const documents = rankSpecs.map(item => createToolSearchDocument(item, item.namespace));
const queries = ["issue", "pull requests", "closed", "thread_read", "dev_app__thread_read", "mcp__dev-app__thread_read", "thread read", "read", "milestones", "kubernetes", "schedules", "matching tokens", "the", "weather"];
const rankings = queries.map(query => new Bm25Ranker().rank(query, documents, 8).map(match => match.name));
const durable = queries.map(query => rankDocuments(query, documents, 8));
const tokens = ["listIssues for the GitHub_repo", "searches queries HTTPServer", "aHTTPServer", "foxes boxes classes"].map(tokenize);
process.stdout.write(JSON.stringify({ offered, results, queries, rankings, durable, tokens }));

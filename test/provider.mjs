import { createServer } from "node:http";
import { writeFile } from "node:fs/promises";

const requests = [];
const server = createServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    requests.push({ target: request.url, authorization: request.headers.authorization, body: JSON.parse(body) });
    const message = requests.length === 1
        ? { role: "assistant", content: null, tool_calls: [{ id: "call-1", type: "function", function: { name: "write", arguments: JSON.stringify({ path: "a.txt", content: "hello" }) } }] }
        : { role: "assistant", content: "done" };
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ choices: [{ message }] }));
    if (requests.length === 2) {
        await writeFile(process.argv[2], JSON.stringify(requests));
        server.close();
    }
});
server.listen(0, "127.0.0.1", () => console.log(server.address().port));

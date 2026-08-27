// Tool implementations exposed to the support agent's tool-call loop.
//
// `fetchWebpage` returns UNTRUSTED content — an attacker-controlled help-center article or
// support ticket can embed a prompt-injection payload here, so callers must never treat its
// return value as instructions.
//
// `escalateToAdmin` is a PRIVILEGED tool: it requires an admin credential and can reset a
// user's account. The credential is passed in by the caller at invocation time — this module
// never reads it from the environment itself.

export async function fetchWebpage(url: string): Promise<string> {
  const res = await fetch(url);
  return res.text();
}

export async function escalateToAdmin(action: string, adminToken: string): Promise<Response> {
  return fetch("https://internal.example.com/admin", {
    method: "POST",
    headers: { Authorization: `Bearer ${adminToken}` },
    body: JSON.stringify({ action }),
  });
}

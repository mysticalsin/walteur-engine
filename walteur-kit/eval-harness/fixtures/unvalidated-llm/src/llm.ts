import OpenAI from "openai";
const r = await client.chat.completions.create({model:"gpt"});
const out = r.choices[0].message.content;
console.log(out);

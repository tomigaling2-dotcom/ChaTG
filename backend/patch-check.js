const fs=require("fs");
const p="server.js";
const s=fs.readFileSync(p,"utf8");
const a=s.indexOf("path === '/image/edit'");
const z=s.indexOf("path === '/image/generate'",a);
if(a<0||z<0)throw new Error("SAFE STOP");
const r=s.slice(a,z);
console.log("EDIT ROUTE FOUND");
console.log(r.includes("await editImage(")?"EDIT CALL FOUND":"EDIT CALL NOT FOUND");

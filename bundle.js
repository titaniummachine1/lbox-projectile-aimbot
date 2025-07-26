import { bundle } from 'luabundle'
import * as fs from 'fs';

// Read the output filename from title.txt
const title = fs.readFileSync('title.txt', 'utf8').trim();

const bundledLua = bundle('./src/main.lua', {
    metadata: false,
    expressionHandler: (module, expression) => {
        const start = expression.loc.start
        console.warn(`WARNING: Non-literal require found in '${module.name}' at ${start.line}:${start.column}`)
    }
});

fs.writeFile(`build/${title}`, bundledLua, err => {
    if (err) {
        console.error(err);
    }
});

console.log(`Library bundle created as build/${title}`);
// Run with Node and Chrome. Uses the actual signature-capture helpers from the Visualforce page.
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const source = fs.readFileSync('force-app/main/default/pages/ESignaturePage.page', 'utf8');
function helper(name) {
    const start = source.indexOf('function ' + name + '(');
    if (start < 0) throw new Error('Missing helper: ' + name);
    const end = source.indexOf('\nfunction ', start + 1);
    return source.slice(start, end < 0 ? undefined : end);
}
const captureCode = ['bottomAlignSignatureInk', 'canvasToSignatureJpeg', 'typedSignatureToJpeg'].map(helper).join('\n');
const chrome = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const browser = spawn(chrome, [
    '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--remote-debugging-pipe', '--user-data-dir=' + path.resolve('.local/signature-test-browser')
], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
let buffer = '', nextId = 0;
const pending = new Map();
const timer = setTimeout(() => {
    console.error('Signature capture test timed out');
    browser.kill();
    process.exitCode = 1;
}, 25000);
browser.on('error', error => { console.error(error); clearTimeout(timer); process.exitCode = 1; });
browser.stdio[4].on('data', chunk => {
    buffer += chunk.toString();
    let end;
    while ((end = buffer.indexOf('\0')) >= 0) {
        const message = JSON.parse(buffer.slice(0, end));
        buffer = buffer.slice(end + 1);
        const request = pending.get(message.id);
        if (!request) continue;
        pending.delete(message.id);
        message.error ? request.reject(message.error) : request.resolve(message.result);
    }
});
function send(method, params = {}, sessionId) {
    return new Promise((resolve, reject) => {
        const id = ++nextId;
        pending.set(id, { resolve, reject });
        browser.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + '\0');
    });
}
(async () => {
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
    const result = await send('Runtime.evaluate', {
        expression: captureCode + '\n(' + (async function () {
            function assert(condition, message) { if (!condition) throw new Error(message); }
            function bounds(canvas) {
                const data = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
                let minX = canvas.width, maxX = -1, minY = canvas.height, maxY = -1, count = 0;
                for (let y = 0; y < canvas.height; y++) for (let x = 0; x < canvas.width; x++) {
                    const i = (y * canvas.width + x) * 4;
                    if (data[i + 3] > 8 && Math.min(data[i], data[i + 1], data[i + 2]) < 245) {
                        minX = Math.min(minX, x); maxX = Math.max(maxX, x);
                        minY = Math.min(minY, y); maxY = Math.max(maxY, y); count++;
                    }
                }
                return { minX, maxX, minY, maxY, count };
            }
            for (const opaque of [false, true]) {
                const canvas = document.createElement('canvas'); canvas.width = 40; canvas.height = 30;
                const ctx = canvas.getContext('2d');
                if (opaque) { ctx.fillStyle = 'white'; ctx.fillRect(0, 0, 40, 30); }
                ctx.fillStyle = '#111111'; ctx.fillRect(8, 5, 18, 7);
                const before = bounds(canvas), aligned = bottomAlignSignatureInk(canvas), after = bounds(aligned);
                assert(aligned.width === 40 && aligned.height === 30, 'Canvas dimensions changed');
                assert(after.maxY === 27, 'Bottom whitespace was not removed');
                assert(after.minX === before.minX && after.maxX === before.maxX &&
                    after.maxY - after.minY === before.maxY - before.minY && after.count === before.count,
                    'Signature ink was scaled or clipped');
                assert(bounds(canvas).maxY === before.maxY, 'Original capture canvas was modified');
                assert(bottomAlignSignatureInk(aligned) === aligned, 'Alignment must be idempotent');
            }
            const blank = document.createElement('canvas'); blank.width = 40; blank.height = 30;
            assert(bottomAlignSignatureInk(blank) === blank, 'Blank capture must be unchanged');
            const jpeg = typedSignatureToJpeg('John Smith');
            const image = new Image(); image.src = jpeg; await image.decode();
            const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
            canvas.getContext('2d').drawImage(image, 0, 0);
            const typedBounds = bounds(canvas);
            assert(image.width === 640 && image.height === 160, 'Typed signature scale changed');
            assert(typedBounds.maxY >= 154, 'Typed signature still has excessive bottom padding');
            return { passed: true, typedBounds, typedJpeg: jpeg };
        }).toString() + ')()', awaitPromise: true, returnByValue: true
    }, sessionId);
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    const { typedJpeg, ...summary } = result.result.value;
    fs.mkdirSync('.local/signature-stamp-preview', { recursive: true });
    fs.writeFileSync('.local/signature-stamp-preview/captured-signature.jpg', Buffer.from(typedJpeg.split(',')[1], 'base64'));
    console.log(JSON.stringify(summary));
    await send('Browser.close');
})().catch(error => { console.error(error); process.exitCode = 1; browser.kill(); }).finally(() => clearTimeout(timer));

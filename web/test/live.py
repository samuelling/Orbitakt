import asyncio, glob, json, time
from playwright.async_api import async_playwright
S="/tmp/claude-0/-home-claude/16a18e65-b654-5413-9a9b-435c2f447f9c/scratchpad/"
async def main():
    txt="\n".join(open(f).read() for f in glob.glob(S+"tle/*"))
    async with async_playwright() as p:
        b=await p.chromium.launch()
        pg=await (await b.new_context()).new_page()
        errs=[]; pg.on("pageerror",lambda e:errs.append(str(e)))
        await pg.goto("http://localhost:8765/play/index.html")
        await pg.evaluate("([t,n])=>{localStorage.setItem('orbitakt.tle',t);localStorage.setItem('orbitakt.tleAt',String(n));localStorage.setItem('orbitakt.tleNext',String(n+43200))}",[txt,time.time()])
        await pg.reload(); await pg.wait_for_timeout(3000)
        print(await pg.evaluate("()=>{const m=window.orbitakt.model;return JSON.stringify({live:m.live,status:m.status,note:m.dataNote,n:m.snapshot.catalogSize,sky:m.snapshot.blips.length,inCone:m.tracks.map(t=>t.inCone)})}"))
        print(errs); await b.close()
asyncio.run(main())

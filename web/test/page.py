import asyncio, sys, json
from playwright.async_api import async_playwright
OUT="/tmp/claude-0/-home-claude/16a18e65-b654-5413-9a9b-435c2f447f9c/scratchpad/shots/"
async def main():
    async with async_playwright() as p:
        b=await p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
        ctx=await b.new_context(viewport={"width":420,"height":900},device_scale_factor=2)
        pg=await ctx.new_page()
        logs=[]
        pg.on("console",lambda m:logs.append(m.type+": "+m.text))
        pg.on("pageerror",lambda e:logs.append("PAGEERROR: "+str(e)))
        await pg.goto("http://localhost:8765/play/index.html")
        await pg.wait_for_timeout(1500)
        await pg.screenshot(path=OUT+"web_idle.png",full_page=True)
        await pg.click("#play")
        await pg.wait_for_timeout(4000)
        st=await pg.evaluate("()=>{const o=window.orbitakt;return {run:o.engine.isRunning,ctx:o.engine.ctx&&o.engine.ctx.state,beam:o.engine.beam(),bpm:o.model.effectiveBPM,status:o.model.status,hits:o.model.tracks.map(t=>t.inCone),sats:o.model.snapshot.blips.length}}")
        print(json.dumps(st))
        await pg.wait_for_timeout(1000)
        b2=await pg.evaluate("()=>window.orbitakt.engine.beam()")
        print("beam later",b2)
        await pg.screenshot(path=OUT+"web_play.png",full_page=True)
        print("\n".join(logs))
        await b.close()
asyncio.run(main())

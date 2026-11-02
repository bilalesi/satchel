"""Assemble the promo: raw takes -> cropped to 16:9 (menu bar strip removed), sped up, camera moves, captions."""
import subprocess, sys, os, json

FPS = 30
OUT = 'satchel-promo.mp4'

def ease(s): return f"(({s})*({s})*(3-2*({s})))"

def track(keys):
    """Piecewise smoothstep through (t, value) keys; `T` is the output time in seconds."""
    def rec(i):
        if i == len(keys) - 1: return f"{keys[-1][1]}"
        (t0, v0), (t1, v1) = keys[i], keys[i + 1]
        s = f"clip((T-{t0})/{t1 - t0},0,1)"
        return f"if(lt(T,{t1}),{v0}+({v1}-{v0})*{ease(s)},{rec(i + 1)})"
    return f"if(lt(T,{keys[0][0]}),{keys[0][1]},{rec(0)})"

def camera(cam):
    z = track([(t, zz) for t, zz, u, v in cam])
    u = track([(t, u) for t, zz, u, v in cam])
    v = track([(t, v) for t, zz, u, v in cam])
    x = f"min(max(({u})*iw-iw/zoom/2,0),iw-iw/zoom)"
    y = f"min(max(({v})*ih-ih/zoom/2,0),ih-ih/zoom)"
    sub = lambda s: s.replace('T', '(on/30)')
    return sub(z), sub(x), sub(y)

def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode: print(' '.join(cmd)[:400]); print(r.stderr[-1500:]); sys.exit(1)

def clip_segment(name, clip, ss, to, speed, y0, cam, caption=None, cap_at=(0.25, None)):
    dur = (to - ss) / speed
    z, x, y = camera(cam)
    top = 66 if y0 == 'top' else 133
    vf = (f"[0:v]crop=3024:1701:0:{top},setpts=(PTS-STARTPTS)/{speed},fps={FPS},"
          f"zoompan=z='{z}':x='{x}':y='{y}':d=1:s=1920x1080:fps={FPS},format=yuv420p[v]")
    inputs = ['-ss', str(ss), '-t', str(to - ss), '-i', f'{clip}.mov']
    if caption:
        a, b = cap_at[0], cap_at[1] if cap_at[1] else dur - 0.25
        inputs += ['-loop', '1', '-framerate', str(FPS), '-t', f'{dur:.3f}', '-i', f'{caption}.png']
        vf += (f";[1:v]format=rgba,fade=t=in:st={a}:d=0.3:alpha=1,fade=t=out:st={b - 0.3}:d=0.3:alpha=1[c];"
               f"[v][c]overlay=x=(W-w)/2:y=H-h-24:shortest=1,format=yuv420p[o]")
        out = '[o]'
    else:
        out = '[v]'
    run(['ffmpeg', '-v', 'error', '-y', *inputs, '-filter_complex', vf, '-map', out, '-t', f'{dur:.3f}',
         '-c:v', 'libx264', '-crf', '17', '-preset', 'medium', '-pix_fmt', 'yuv420p', '-r', str(FPS), f'seg_{name}.mp4'])
    return dur

def card_segment(name, card, dur, zoom=0.03):
    vf = (f"zoompan=z='1+{zoom}*on/({dur}*{FPS})':x='iw/2-iw/zoom/2':y='ih/2-ih/zoom/2':d=1:s=1920x1080:fps={FPS},"
          f"fade=t=in:st=0:d=0.5,fade=t=out:st={dur - 0.5}:d=0.5,format=yuv420p")
    run(['ffmpeg', '-v', 'error', '-y', '-loop', '1', '-framerate', str(FPS), '-t', str(dur), '-i', f'{card}.png',
         '-vf', vf, '-t', str(dur), '-c:v', 'libx264', '-crf', '17', '-preset', 'medium', '-pix_fmt', 'yuv420p', '-r', str(FPS), f'seg_{name}.mp4'])
    return dur

# Camera keys: (seconds in the output, zoom, focus x, focus y) with focus in 0..1 over the cropped 16:9 frame.
segments = [
    ('title', 'card', 'card_title', 3.0),
    ('t1', 'clip', dict(clip='tourA', ss=3.6, to=10.2, speed=2.0, y0='top', cap='cap_tour1',
        cam=[(0, 1.0, .5, .5), (1.6, 1.25, .30, .35), (3.3, 1.35, .32, .30)])),
    ('t2', 'clip', dict(clip='tourA', ss=10.7, to=14.7, speed=1.0, y0='top', cap='cap_tour2',
        cam=[(0, 1.0, .5, .4), (0.9, 1.9, .5, .09), (2.5, 1.9, .5, .10), (3.5, 1.35, .5, .42), (4.0, 1.3, .5, .45)])),
    ('t3', 'clip', dict(clip='tourA', ss=14.7, to=17.4, speed=1.6, y0='top', cap=None,
        cam=[(0, 1.3, .5, .45), (1.7, 1.0, .5, .5)])),
    ('t4', 'clip', dict(clip='tourA', ss=17.4, to=32.0, speed=3.6, y0='top', cap='cap_tour3',
        cam=[(0, 1.0, .5, .5), (2.0, 1.2, .38, .45), (4.05, 1.25, .5, .45)])),
    ('y1', 'clip', dict(clip='syncB', ss=4.5, to=7.5, speed=2.0, y0='top', cap='cap_sync1',
        cam=[(0, 1.0, .5, .5), (1.5, 1.6, .5, .38)])),
    ('y2', 'clip', dict(clip='syncB', ss=9.0, to=15.0, speed=1.8, y0='top', cap='cap_sync2',
        cam=[(0, 1.6, .55, .36), (3.3, 1.9, .62, .43)])),
    ('y3', 'clip', dict(clip='syncB', ss=15.5, to=24.5, speed=3.0, y0='top', cap=None,
        cam=[(0, 1.7, .55, .40), (3.0, 1.6, .55, .45)])),
    ('y4', 'clip', dict(clip='syncB', ss=25.8, to=31.4, speed=1.4, y0='top', cap='cap_sync3',
        cam=[(0, 1.4, .5, .28), (1.6, 1.9, .5, .09), (2.9, 1.9, .5, .10), (4.0, 1.5, .62, .38)])),
    ('u2', 'clip', dict(clip='updateD', ss=8.6, to=11.6, speed=1.0, y0='top', cap='cap_upd1',
        cam=[(0, 1.0, .5, .3), (0.6, 1.9, .5, .09), (3.0, 1.9, .5, .10)])),
    ('u3', 'clip', dict(clip='updateD', ss=14.0, to=20.6, speed=2.2, y0='bottom', cap='cap_upd2',
        cam=[(0, 1.5, .14, .92), (1.5, 1.6, .12, .85), (3.0, 1.6, .12, .8)])),
    ('c1', 'clip', dict(clip='customC', ss=4.2, to=13.5, speed=2.4, y0='top', cap='cap_cus1',
        cam=[(0, 1.6, .16, .22), (3.9, 1.6, .16, .27)])),
    ('c2', 'clip', dict(clip='customC', ss=17.0, to=22.0, speed=2.0, y0='top', cap='cap_cus2',
        cam=[(0, 1.5, .12, .32), (2.5, 1.5, .12, .38)])),
    ('q1', 'clip', dict(clip='quickE', ss=4.3, to=13.6, speed=2.3, y0='bottom', cap='cap_quick',
        cam=[(0, 1.3, .12, .85), (1.1, 1.3, .12, .85), (1.7, 1.5, .5, .32), (4.0, 1.5, .5, .32)])),
    ('ext', 'card', 'card_extension', 3.2),
    ('outro', 'card', 'card_outro', 4.0),
]

if __name__ == '__main__':
    only = set(sys.argv[1:])
    total = 0
    names = []
    for seg in segments:
        name = seg[0]
        if seg[1] == 'card':
            dur = seg[3]
            if not only or name in only: card_segment(name, seg[2], dur)
        else:
            c = seg[2]
            dur = (c['to'] - c['ss']) / c['speed']
            if not only or name in only:
                clip_segment(name, c['clip'], c['ss'], c['to'], c['speed'], c['y0'], c['cam'], c['cap'])
        total += dur; names.append(name)
        print(f'{name}: {dur:.2f}s')
    print(f'total {total:.1f}s')
    with open('concat.txt', 'w') as f:
        for n in names: f.write(f"file 'seg_{n}.mp4'\n")
    if not only:
        run(['ffmpeg', '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', 'concat.txt', '-c', 'copy', '-movflags', '+faststart', OUT])
        print('wrote', OUT)

from pathlib import Path
import shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2]
APP=ROOT/'scrcpy-5.0.1/app'
with tempfile.TemporaryDirectory(prefix='jh-corner-check-') as directory:
    output=Path(directory)/'check'
    flags=shlex.split(subprocess.check_output(['/opt/homebrew/bin/pkg-config','--cflags','--libs','sdl3'],text=True))
    subprocess.run(['clang','-fobjc-arc','-Wall','-Wextra','-Werror','-I'+str(APP/'src'),'-I'+str(ROOT/'scrcpy-5.0.1/build/app'),
        str(Path(__file__).with_name('dot.m')),str(APP/'src/macos_window.m'),*flags,'-framework','Cocoa','-framework','QuartzCore','-o',str(output)],check=True)
    process=subprocess.Popen([str(output)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    process.stdin.write('AW_COMMAND:tools-visible\nAW_COMMAND:keep-active\n');process.stdin.flush()
    lines=[]
    while True:
        line=process.stdout.readline()
        if not line:break
        lines.append(line)
        if line.startswith('PASS: corner'):break
    process.stdin.close();process.stdin=None
    out,err=process.communicate(timeout=10)
    out=''.join(lines)+out
    print(out);assert process.returncode==0,(process.returncode,err)
    assert out.count('AW_TOOLS_TOGGLE')==1

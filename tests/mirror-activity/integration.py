from pathlib import Path
import shlex,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
SRC=ROOT/'scrcpy-5.0.1/server/src/main/java/com/genymobile/scrcpy'
JAVA=Path('/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home/bin')
with tempfile.TemporaryDirectory(prefix='jh-activity-') as directory:
    sources=['control/ControlMessage.java','control/ControlMessageReader.java','control/ControlProtocolException.java',
        'model/Position.java','model/Point.java','model/Size.java','util/Binary.java']
    subprocess.run([str(JAVA/'javac'),'-classpath',str(ROOT/'.android-sdk/platforms/android-36/android.jar'),'-sourcepath',str(SRC.parents[2]),'-d',directory,*(str(SRC/name) for name in sources),str(HERE/'ActivityCheck.java')],check=True)
    subprocess.run([str(JAVA/'java'),'-cp',directory+':'+str(ROOT/'.android-sdk/platforms/android-36/android.jar'),'ActivityCheck'],check=True,timeout=10)
    flags=shlex.split(subprocess.check_output(['/opt/homebrew/bin/pkg-config','--cflags','--libs','sdl3'],text=True))
    app=ROOT/'scrcpy-5.0.1/app'
    output=Path(directory)/'pulse'
    subprocess.run(['clang','-Wall','-Wextra','-Werror','-I'+str(app/'src'),'-I'+str(ROOT/'scrcpy-5.0.1/build/app'),
        str(HERE/'pulse.c'),*(str(app/'src'/name) for name in ['control_msg.c','util/str.c','util/strbuf.c']),*flags,'-o',str(output)],check=True)
    subprocess.run([str(output)],check=True,timeout=10)
    print('PASS: C pulse serialization is one byte, carries no input/unlock data, and may drop under congestion.')

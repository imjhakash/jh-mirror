from pathlib import Path
import subprocess
import tempfile
import zipfile
import os
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SDK = ROOT/'.android-sdk'
TOOLS = SDK/'build-tools/36.0.0'
JAVA = Path('/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home/bin')
os.environ['JAVA_HOME'] = str(JAVA.parent)
OUT = Path('/private/tmp/jh-phone-ui-check.apk')
with tempfile.TemporaryDirectory(prefix='jh-phone-ui-') as directory:
    work = Path(directory); (work/'classes').mkdir(); (work/'dex').mkdir()
    subprocess.run([str(JAVA/'javac'),'--release','8','-classpath',str(SDK/'platforms/android-36/android.jar'),'-d',str(work/'classes'),str(HERE/'FixtureProvider.java'),str(HERE/'PhoneUiCheck.java')],check=True)
    subprocess.run([str(TOOLS/'d8'),'--min-api','26','--lib',str(SDK/'platforms/android-36/android.jar'),'--output',str(work/'dex'),*(str(p) for p in (work/'classes').rglob('*.class'))],check=True)
    subprocess.run([str(TOOLS/'aapt2'),'link','-o',str(work/'unsigned.apk'),'-I',str(SDK/'platforms/android-36/android.jar'),'--manifest',str(HERE/'AndroidManifest.xml')],check=True)
    with zipfile.ZipFile(work/'unsigned.apk','a',compression=zipfile.ZIP_DEFLATED) as archive: archive.write(work/'dex/classes.dex','classes.dex')
    subprocess.run([str(TOOLS/'zipalign'),'-f','4',str(work/'unsigned.apk'),str(work/'aligned.apk')],check=True)
    subprocess.run([str(TOOLS/'apksigner'),'sign','--ks',str(ROOT/'android/build/personal-signing.keystore'),'--ks-key-alias','androidwireless','--ks-pass','pass:android','--key-pass','pass:android','--out',str(OUT),str(work/'aligned.apk')],check=True)
    subprocess.run([str(TOOLS/'apksigner'),'verify',str(OUT)],check=True)
print('Built generated-only Android UI test:',OUT)

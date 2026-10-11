import subprocess,json,re,hashlib,datetime,concurrent.futures
from pathlib import Path
import numpy as np
ROOT=Path('/Users/chugs/Documents/Codex/2026-10-03/ok-ba')
FF=str(ROOT/'outputs/CueLevel/CueLevel.app/Contents/Resources/ffmpeg')
OUT=ROOT/'outputs/CueLevel/Reference Library'
PATHS=[Path(p) for p in ['/Users/chugs/Downloads/Telegram Desktop/21 Arti w_ Jaynaad.wav','/Users/chugs/Desktop/Music/Instrumentals/Bal Geet.wav','/Users/chugs/Downloads/Cue 24B_Sayukta 2.wav','/Users/chugs/Downloads/Cue 18B_Balak 2.wav','/Users/chugs/Downloads/Cue 21A_Kishore 1.wav','/Users/chugs/Downloads/Telegram Desktop/Act1_Scene1  Mix.wav']]
def run(args):
 p=subprocess.run([FF,'-nostdin','-hide_banner',*args],capture_output=True,timeout=600)
 if p.returncode: raise RuntimeError(p.stderr.decode()[-1500:])
 return p

def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
def db(x):return round(float(10*np.log10(max(x,1e-20))),3)
def analyse(p):
 original_hash=digest(p)
 log=run(['-i',str(p),'-map','0:a:0','-af','loudnorm=print_format=json','-f','null','-']).stderr.decode()
 (ROOT/'work/reference-analysis'/f'{p.stem}-native.log').write_text(log)
 native=json.loads(log[log.rfind('{'):log.rfind('}')+1])
 meta=re.search(r'Audio: ([^\n]+)',log).group(1)
 stereo_log=run(['-i',str(p),'-map','0:a:0','-af','aformat=channel_layouts=stereo,loudnorm=print_format=json','-f','null','-']).stderr.decode()
 stereo=json.loads(stereo_log[stereo_log.rfind('{'):stereo_log.rfind('}')+1])
 pcm=run(['-v','error','-i',str(p),'-map','0:a:0','-af','aformat=channel_layouts=stereo','-ar','48000','-f','f32le','-']).stdout
 x=np.frombuffer(pcm,dtype='<f4').reshape(-1,2).astype(np.float64); del pcm
 count=len(x);rate=48000
 energy=np.mean(x*x,axis=0);peak=float(np.max(np.abs(x)))
 frame=48000; blocks=count//frame
 rms=np.mean(x[:blocks*frame].reshape(blocks,frame,2)**2,axis=(1,2))
 # Relative spectrum of combined left/right power, using Hann-windowed FFT frames; not an EQ target.
 n=8192;window=np.hanning(n);power=np.zeros(n//2+1)
 for start in range(0,count-n+1,n//2):
  fft=np.fft.rfft(x[start:start+n]*window[:,None],axis=0)
  power+=np.mean(abs(fft)**2,axis=1)
 hz=np.fft.rfftfreq(n,1/rate); total=power[(hz>=20)&(hz<20000)].sum()
 bands=[(20,80),(80,250),(250,1000),(1000,2500),(2500,6000),(6000,12000),(12000,20000)]
 spectrum=[{'low_hz':a,'high_hz':b,'power_fraction':round(float(power[(hz>=a)&(hz<b)].sum()/total),6)} for a,b in bands]
 corr=float(np.sum(x[:,0]*x[:,1])/np.sqrt(np.sum(x[:,0]**2)*np.sum(x[:,1]**2)))
 assert digest(p)==original_hash,'Source changed during analysis'
 def levels(d):return {'integrated_lufs':float(d['input_i']),'true_peak_dbtp':float(d['input_tp']),'loudness_range_lu':float(d['input_lra'])}
 result={'id':original_hash[:16],'name':p.name,'sha256':original_hash,'bytes':p.stat().st_size,'category':None,'category_status':'awaiting user confirmation','approved_by_user_as_reference':True,'distribution_rights':'not granted; local reference use only','source_format':meta,'duration_seconds':round(count/rate,6),'native':levels(native),'cuelevel_stereo':levels(stereo),'stereo_measurement_method':'FFmpeg aformat=channel_layouts=stereo; same channel conversion as CueLevel','sample_peak_dbfs':round(20*np.log10(max(peak,1e-20)),3),'crest_factor_db':round(20*np.log10(max(peak,1e-20))-db(float(np.mean(energy))),3),'left_rms_dbfs':db(energy[0]),'right_rms_dbfs':db(energy[1]),'uncentred_stereo_correlation':round(corr,5),'samples_at_or_above_full_scale':int(np.count_nonzero(abs(x)>=1.0)),'spectrum':spectrum,'timeline_1s_rms_dbfs':[db(v) for v in rms]}
 annotations_path = OUT/'annotations.json'
 if annotations_path.exists():
  result.update(json.loads(annotations_path.read_text()).get('by_source_sha256',{}).get(original_hash,{}))
 (OUT/(result['id']+'.json')).write_text(json.dumps(result,indent=2))
 print(p.name,result['native'],result['cuelevel_stereo'],meta,flush=True)
 return result
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: records=list(pool.map(analyse,PATHS))
library={'schema_version':1,'created_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'purpose':'Private CueLevel calibration reference measurements. Not a trained model; no automatic EQ matching or global default change.','analysis_version':'FFmpeg 7.1 loudnorm input measurements; NumPy FFT; 48 kHz stereo RMS/spectrum','records':records}
(OUT/'library.json').write_text(json.dumps(library,indent=2))
(ROOT/'work/reference-analysis/private-source-map.json').write_text(json.dumps({r['id']:str(p) for r,p in zip(records,PATHS)},indent=2))

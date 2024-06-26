# Setup
Special HW assesment for TPM2.0 testing: [intel-
nuc-01.wlan.rhts.bos.redhat.com](http://intel-nuc-01.wlan.rhts.bos.redhat.com)
or tpm-pbd-machines pool machines.

[hardware]  
hostrequire =

<and>  
<pool op="=" value="tpm-pbd-machines"/>  
<system_type value="Resource"/>  
</and>

OLD:

hostrequire =

<and>  
<or>  
    <hostname op="=" value="intel-nuc-01.wlan.rhts.bos.redhat.com"/>  
    <pool op="=" value="tpm-pbd-machines"/>  
</or>  
<or>  
    <system_type value="Machine"/>  
    <system_type value="Resource"/>  
</or>  
</and>

OBSOLTED:

Can be run only on [HW compatible with
TPM2.0](https://wiki.test.redhat.com/Kernel/HardwareEnablement/TPM_testing_status#ListofHW
"HW compatible with TPM2.0")

hostrequire = <or>  
  <hostname op="=" value="dell-pem630-01.rhts.eng.bos.redhat.com"/>  
  <hostname op="=" value="dell-per230-03.khw.lab.eng.bos.redhat.com"/>  
  <hostname op="=" value="dell-per630-01.khw.lab.eng.bos.redhat.com"/>  
  <hostname op="=" value="hp-z4-g4-01.ml3.eng.bos.redhat.com"/>  
  <hostname op="=" value="hp-z6-g4-01.rhts.bos.redhat.com"/>  
  <hostname op="=" value="hp-z8-g4-01.khw.lab.eng.bos.redhat.com"/>  
  <hostname op="=" value="intel-bakersville-01.khw1.lab.eng.bos.redhat.com"/>  
  <hostname op="=" value="intel-coffeelake-s-01.lab.eng.rdu.redhat.com"/>  
  <hostname op="=" value="intel-purley-03.khw1.lab.eng.bos.redhat.com"/>  
  <hostname op="=" value="intel-purley-fpga-01.khw1.lab.eng.bos.redhat.com"/>  
  <hostname op="=" value="intel-purley-lr-01.ml3.eng.bos.redhat.com"/>  
  <hostname op="=" value="intel-purley-lr-02.khw1.lab.eng.bos.redhat.com"/>  
  <hostname op="=" value="lenovo-sr650-01.lab.eng.rdu.redhat.com"/>  
  <hostname op="=" value="lenovo-sr650-02.lab.eng.rdu.redhat.com"/>  
  <hostname op="=" value="seceng-idm-1.idm.lab.eng.rdu.redhat.com"/>  
  <hostname op="=" value="dell-pem640-01.lab.bos.redhat.com"/>  
  <hostname op="=" value="dell-per840-01.rhts.eng.bos.redhat.com"/>  
  <hostname op="=" value="dell-per940-01.rhts.eng.bos.redhat.com"/>  
  <hostname op="=" value="dell-per740-02.klab.eng.bos.redhat.com"/>  
  <hostname op="=" value="dell-per830-01.khw.lab.eng.bos.redhat.com"/>  
  <hostname op="=" value="dell-per730-01.khw.lab.eng.bos.redhat.com"/>  
</or>


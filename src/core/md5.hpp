#pragma once
#include <cstddef>
#include <cstdint>
#include <string>

namespace splay {
    // RFC 1321 MD5, as lowercase hexadecimal. Syncplay's Hello carries the
    // server password as this digest; it is wire compatibility, not password
    // protection. One portable implementation keeps the tested code identical
    // to the Windows release build.
    inline std::string md5_hex(const std::string& input){
        static constexpr uint32_t sines[64]={
            0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,
            0xa8304613,0xfd469501,0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,
            0x6b901122,0xfd987193,0xa679438e,0x49b40821,0xf61e2562,0xc040b340,
            0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
            0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,
            0x676f02d9,0x8d2a4c8a,0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,
            0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,0x289b7ec6,0xeaa127fa,
            0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
            0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,
            0xffeff47d,0x85845dd1,0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,
            0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391};
        static constexpr unsigned shifts[16]={7,12,17,22,5,9,14,20,4,11,16,23,6,10,15,21};
        uint32_t state[4]={0x67452301,0xefcdab89,0x98badcfe,0x10325476};
        uint32_t words[16];
        unsigned char tail[128];
        auto compress=[&](const unsigned char* block){
            for(int n=0;n<16;++n)words[n]=uint32_t(block[n*4])|uint32_t(block[n*4+1])<<8|
                uint32_t(block[n*4+2])<<16|uint32_t(block[n*4+3])<<24;
            uint32_t a=state[0],b=state[1],c=state[2],d=state[3];
            for(int n=0;n<64;++n){
                uint32_t mix;
                int word;
                if(n<16){mix=(b&c)|(~b&d);word=n;}
                else if(n<32){mix=(d&b)|(~d&c);word=(5*n+1)%16;}
                else if(n<48){mix=b^c^d;word=(3*n+5)%16;}
                else{mix=c^(b|~d);word=(7*n)%16;}
                mix+=a+sines[n]+words[word];
                const unsigned shift=shifts[(n/16)*4+n%4];
                a=d;d=c;c=b;
                b+=(mix<<shift)|(mix>>(32-shift));
            }
            state[0]+=a;state[1]+=b;state[2]+=c;state[3]+=d;
        };
        const auto* data=reinterpret_cast<const unsigned char*>(input.data());
        const size_t size=input.size(),whole=size-size%64,rest=size-whole;
        for(size_t at=0;at<whole;at+=64)compress(data+at);
        // Padding: 0x80, zeros to 56 mod 64, then the bit length, little-endian.
        const size_t padded=rest<56?64:128;
        for(size_t n=0;n<padded;++n)tail[n]=n<rest?data[whole+n]:0;
        tail[rest]=0x80;
        const uint64_t bits=uint64_t(size)*8;
        for(int n=0;n<8;++n)tail[padded-8+n]=static_cast<unsigned char>(bits>>(8*n));
        for(size_t at=0;at<padded;at+=64)compress(tail+at);
        std::string result;
        for(uint32_t value:state)for(int n=0;n<4;++n){
            const unsigned byte=(value>>(8*n))&255;
            result+="0123456789abcdef"[byte>>4];
            result+="0123456789abcdef"[byte&15];
        }
        // The working buffers held password bytes.
        volatile unsigned char* erase=tail;
        for(size_t n=0;n<sizeof(tail);++n)erase[n]=0;
        volatile uint32_t* erase_words=words;
        for(size_t n=0;n<16;++n)erase_words[n]=0;
        return result;
    }
}

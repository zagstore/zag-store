/* Zag Store standalone-provisioning prototype: offline self-test of the
 * apple-auth clean-room ADI core on stock iOS. No network, no Apple contact.
 * Output is sanitized: statuses, lengths and a persistence round-trip only;
 * never raw identity bytes, keys or provisioning payloads. */
#include <apple_auth/c_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int nonzero(const unsigned char* p, size_t n){ for(size_t i=0;i<n;i++) if(p[i]) return 1; return 0; }

/* Writes a sanitized JSON report to `out`. `state_path` persists the encrypted
 * state blob (the device Documents dir on iOS). Returns 0 if every self-contained
 * offline primitive succeeded. */
int zag_apple_auth_selftest(const char* state_path, char* out, size_t cap){
    char b[2048]; size_t off=0; int overall=0;
    #define EMIT(...) do{ off+=snprintf(b+off,sizeof(b)-off,__VA_ARGS__);}while(0)
    EMIT("{\"library_version\":\"%s\"", aauth_version());

    /* 1. local identity init */
    unsigned char hw[AAUTH_HARDWARE_ID_SIZE];
    aauth_status s_hw = aauth_local_hardware_id(hw, sizeof(hw));
    EMIT(",\"identity\":{\"status\":%d,\"len\":%d,\"nonzero\":%s}",
         s_hw, AAUTH_HARDWARE_ID_SIZE, (s_hw==AAUTH_OK&&nonzero(hw,sizeof(hw)))?"true":"false");
    if(s_hw!=AAUTH_OK) overall=1;

    /* 2. state handling: generate key, encrypt a marker, PERSIST, reload, decrypt */
    size_t keylen=32;            /* session keys are exactly 32 raw bytes */
    unsigned char* key=malloc(keylen);
    aauth_status s_key=aauth_session_key_generate(key,keylen);
    const char* marker="zag-apple-auth-ios-prototype-2026-11-23";
    size_t plen=strlen(marker);
    size_t clen=0; aauth_session_encrypt((const unsigned char*)marker,plen,key,keylen,NULL,0,&clen);
    unsigned char* blob=malloc(clen);
    aauth_status s_enc=aauth_session_encrypt((const unsigned char*)marker,plen,key,keylen,blob,clen,&clen);
    int persisted=0, roundtrip=0;
    if(s_enc==AAUTH_OK && state_path){
        FILE* f=fopen(state_path,"wb");
        if(f){ persisted=(fwrite(blob,1,clen,f)==clen); fclose(f); }
        if(persisted){
            FILE* g=fopen(state_path,"rb");
            if(g){ unsigned char* rd=malloc(clen); size_t n=fread(rd,1,clen,g); fclose(g);
                size_t dlen=0; aauth_session_decrypt(rd,n,key,keylen,NULL,0,&dlen);
                unsigned char* pt=malloc(dlen);
                aauth_status s_dec=aauth_session_decrypt(rd,n,key,keylen,pt,dlen,&dlen);
                roundtrip=(s_dec==AAUTH_OK && dlen==plen && memcmp(pt,marker,plen)==0);
                free(rd); free(pt);
            }
        }
    }
    EMIT(",\"state\":{\"key_len\":%zu,\"blob_len\":%zu,\"persisted\":%s,\"roundtrip_ok\":%s}",
         keylen,clen,persisted?"true":"false",roundtrip?"true":"false");
    if(!(s_key==AAUTH_OK&&s_enc==AAUTH_OK&&persisted&&roundtrip)) overall=1;

    /* 3. anisette OTP time counter */
    uint32_t counter=0; aauth_status s_tc=aauth_time_counter((int64_t)time(NULL),&counter);
    EMIT(",\"otp_counter\":{\"status\":%d,\"value\":%u}", s_tc, counter);

    /* 4. GrandSlam SRP client start (random ephemeral) */
    aauth_srp* srp=NULL; aauth_status s_sc=aauth_srp_create(NULL,0,&srp);
    size_t publen=0; int pub_nonzero=0;
    if(s_sc==AAUTH_OK){ aauth_srp_public_key(srp,NULL,0,&publen);
        unsigned char* pub=malloc(publen);
        if(aauth_srp_public_key(srp,pub,publen,&publen)==AAUTH_OK) pub_nonzero=nonzero(pub,publen);
        free(pub); aauth_srp_free(srp); }
    EMIT(",\"srp_client\":{\"status\":%d,\"public_len\":%zu,\"nonzero\":%s}",
         s_sc,publen,pub_nonzero?"true":"false");
    if(s_sc!=AAUTH_OK) overall=1;

    /* 5. ADI provisioning entry executes (synthetic challenge -> defined status,
     * proving the provisioning code path runs on-device and validates input;
     * a real spim from Apple is required for success, which this test never contacts). */
    unsigned char challenge[56]; memset(challenge,0,sizeof(challenge));
    aauth_provisioning* prov=NULL;
    aauth_status s_pb=aauth_provisioning_begin(challenge,sizeof(challenge),hw,
        (uint32_t)time(NULL),NULL,0,NULL,NULL,&prov);
    EMIT(",\"provisioning_begin\":{\"status\":%d,\"executed\":true}", s_pb);
    if(prov) aauth_provisioning_free(prov);

    EMIT(",\"overall_ok\":%s}", overall==0?"true":"false");
    free(key); free(blob);
    if(off>=sizeof(b)) return 2;
    if(out && cap) { strncpy(out,b,cap-1); out[cap-1]=0; }
    return overall;
}

#ifdef ZAG_SELFTEST_MAIN
int main(int argc,char**argv){
    char out[2048];
    int rc=zag_apple_auth_selftest(argc>1?argv[1]:"/tmp/zag_state.bin",out,sizeof(out));
    printf("%s\n",out);
    return rc;
}
#endif

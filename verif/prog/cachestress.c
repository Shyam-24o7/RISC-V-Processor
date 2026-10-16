/* Drives the L1 data cache through every miss path, checked against Spike
   like any other program:
     - conflict misses and dirty evictions: three arrays aligned to the size of
       one cache way map onto the same sets, so two ways cannot hold them
     - capacity misses: a working set twice the size of the cache
     - byte and halfword stores into lines already in the cache
   Every array is written before it is read: .bss is not zeroed by crt0, and
   Spike and the RTL would otherwise start from different contents. */

#define WAY_BYTES 2048                  /* 128 sets x 16-byte lines */
#define N   (WAY_BYTES / 4 / 2)         /* 256 words: 1 KiB per array */
#define BIG 2048                        /* 8 KiB: twice the cache */

static volatile unsigned a[N] __attribute__((aligned(WAY_BYTES)));
static volatile unsigned b[N] __attribute__((aligned(WAY_BYTES)));
static volatile unsigned c[N] __attribute__((aligned(WAY_BYTES)));
static volatile unsigned big[BIG];

int main(void) {
    unsigned sum = 0;

    for (int i = 0; i < N; i++) {
        a[i] = i;
        b[i] = i * 3;
        c[i] = i * 7;
    }
    for (int r = 0; r < 4; r++)
        for (int i = 0; i < N; i += 4) {
            a[i] += b[i];
            b[i] += c[i];
            c[i] += a[i];
        }
    for (int i = 0; i < N; i++)
        sum += a[i] ^ b[i] ^ c[i];

    for (int i = 0; i < BIG; i++)
        big[i] = i ^ sum;
    for (int r = 0; r < 2; r++)
        for (int i = 0; i < BIG; i += 4)
            sum += big[i];

    volatile unsigned char  *pb = (volatile unsigned char  *)a;
    volatile unsigned short *ph = (volatile unsigned short *)b;
    for (int i = 0; i < 64; i++) {
        pb[i] = (unsigned char)(i * 5);
        ph[i] = (unsigned short)(i * 9);
    }
    for (int i = 0; i < 16; i++)
        sum += a[i] + b[i];

    return (int)sum;
}

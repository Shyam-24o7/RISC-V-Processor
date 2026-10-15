/* Exercises the ALU, loads and stores, branches, and multiply/divide through
   libgcc (RV32I has no M extension). No I/O: the testbench compares register
   traces against Spike, not printed output. */
int main(void) {
    volatile int arr[8];
    int sum = 0;

    for (int i = 0; i < 8; i++)
        arr[i] = i * 3 + 1;

    for (int i = 0; i < 8; i++)
        sum += arr[i];

    int prod = sum * 7;
    int quot = prod / 5;
    int rem  = prod % 5;

    return sum + prod + quot + rem;
}

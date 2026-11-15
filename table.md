**Here is a cheat sheet to help you visualize them:**

| Register (32-bit) | Register (64-bit) | Traditional Role | System Call Role (32-bit `int 0x80`) | System Call Role (64-bit `syscall`) |
| :--- | :--- | :--- | :--- | :--- |
| **`eax`** | **`rax`** | Math / Accumulator | **Action** (e.g., 4 = write) | **Action** (e.g., 1 = write) |
| **`ebx`** | **`rbx`** | Base Address | **Destination** (e.g., 1 = screen) | (Not usually used) |
| **`ecx`** | **`rcx`** | Loop Counter | **Address** of data | (Not usually used) |
| **`edx`** | **`rdx`** | Data | **Length** of data | **Length** of data |
| **`edi`** | **`rdi`** | Destination Index | (Not usually used) | **Destination** (e.g., 1 = screen) |
| **`esi`** | **`rsi`** | Source Index | (Not usually used) | **Address** of data |
| **`esp`** | **`rsp`** | Stack Pointer | Points to the top of the stack | Points to the top of the stack |
| **`ebp`** | **`rbp`** | Base Pointer | Points to the base of the stack frame | Points to the base of the stack frame |


### The Streamlined Register Table

| 32-bit (Linux `int 0x80`) | 64-bit (Linux `syscall`) | Traditional Role | System Call Role (The OS Rule) |
| :--- | :--- | :--- | :--- |
| **`eax`** | **`rax`** | **Accumulator** (Math) | **Action Number** (e.g., Write, Exit) |
| **`ebx`** | **`rdi`** | **Base** / Destination | **Destination** (e.g., 1 = screen) |
| **`ecx`** | **`rsi`** | **Counter** / Source | **Address** of the data (where it starts) |
| **`edx`** | **`rdx`** | **Data** | **Length** of the data (how many bytes) |
| **`esp`** | **`rsp`** | **Stack Pointer** | Points to the top of the stack |

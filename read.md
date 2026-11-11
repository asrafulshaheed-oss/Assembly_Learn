For **32-bit Linux (`int 0x80`)**, the rulebook is:
*   **`eax`**: The Action Number (What do you want me to do?) -> `4` means "Write".
*   **`ebx`**: The Destination (Where should I write it?) -> `1` means "The Screen".
*   **`ecx`**: The Address (What should I write?) -> Put the memory address of your text here.
*   **`edx`**: The Size (How much should I write?) -> Put the number of bytes here.

If you put the length in `ebx` instead of `edx`, Linux will look at `ebx` expecting the destination, see a number like `10`, and try to write your text to a file called "10". It won't work. **You must follow their rules.**

---

### 3. 32-bit vs. 64-bit: What's with the `e` and `r`?

As computers got better, we moved from 32-bit to 64-bit. 
*   In **32-bit**, registers were 32 bits wide. They started with **`e`** (for Extended). Example: **`e`**`ax`.
*   In **64-bit**, registers became 64 bits wide. They start with **`r`** (for Register). Example: **`r`**`ax`.

So, `eax` and `rax` are exactly the same physical register. `rax` is just twice as big as `eax`.

**(Fun fact: `eax` is just the bottom half of `rax`. If you put a number in `eax`, the top half of `rax` gets wiped out!)**

---

### 4. The 64-bit Rulebook (Why `rdi` and `rsi` appeared)

When 64-bit Linux was invented, the engineers looked at the old rulebook and said, *"We need more registers to pass arguments, because we can do more complex things now."*

They introduced `rdi` and `rsi` (and others) into the system call rules.

For **64-bit Linux (`syscall`)**, the rulebook completely changed:
*   **`rax`**: The Action Number (`1` means "Write").
*   **`rdi`**: The Destination (`1` means "The Screen"). *(Notice they didn't use `rbx` anymore!)*
*   **`rsi`**: The Address of the text. *(Notice they didn't use `rcx`!)*
*   **`rdx`**: The Size. (This one stayed the same).

**This is why you got confused.** You saw `eax`, `ebx`, `ecx` in one tutorial, and `rdi`, `rsi`, `rdx` in another. They are just two different rulebooks for two different systems.

---

### Summary Table

Here is a cheat sheet to help you visualize them:

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

**The Golden Rule:** If you are just doing math (`mov eax, 5`, `add eax, ebx`), you can use any of them. If you are asking the OS to do something (`int 0x80` or `syscall`), you **must** put the right values in the exact registers the OS demands.

### The Streamlined Register Table

| 32-bit (Linux `int 0x80`) | 64-bit (Linux `syscall`) | Traditional Role | System Call Role (The OS Rule) |
| :--- | :--- | :--- | :--- |
| **`eax`** | **`rax`** | **Accumulator** (Math) | **Action Number** (e.g., Write, Exit) |
| **`ebx`** | **`rdi`** | **Base** / Destination | **Destination** (e.g., 1 = screen) |
| **`ecx`** | **`rsi`** | **Counter** / Source | **Address** of the data (where it starts) |
| **`edx`** | **`rdx`** | **Data** | **Length** of the data (how many bytes) |
| **`esp`** | **`rsp`** | **Stack Pointer** | Points to the top of the stack |

---

### ⚠️ One Important Clarification
Look at `eax`/`rax` vs `ebx`/`rdi`. 
*   `eax` and `rax` are the **same physical hardware register**. `eax` is just the bottom 32 bits of `rax`.
*   `ebx` and `rdi` are **completely different physical registers**. They don't overlap at all. 

We pair them in this table because they represent the **same "slot"** in the OS rulebook. 

*   If you are writing 32-bit code, the OS says: *"Put the destination in slot 2."* You use **`ebx`** for slot 2.
*   If you are writing 64-bit code, the OS says: *"Put the destination in slot 2."* You use **`rdi`** for slot 2.

### Let's see it in action

Here is how you write the exact same "Print Hello" program in both 32-bit and 64-bit. Look at how the registers swap according to the table:

**32-bit Version:**
```assembly
mov eax, 4      ; Action: Write
mov ebx, 1      ; Destination: Screen
mov ecx, msg    ; Address: msg
mov edx, 6      ; Length: 6 bytes
int 0x80        ; Call OS
```

**64-bit Version:**
```assembly
mov rax, 1      ; Action: Write (Note: 64-bit uses 1 for write, not 4!)
mov rdi, 1      ; Destination: Screen
mov rsi, msg    ; Address: msg
mov rdx, 6      ; Length: 6 bytes
syscall         ; Call OS
```



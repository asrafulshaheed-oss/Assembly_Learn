# Assembly_Learn

Here is basic Assembly learning journey. It's structured like a CSE110 course but focused on the skills you'll need for exploitation. Every section is collapsible to keep things tidy, with examples, explanations, and hand-picked beginner-friendly YouTube links.

---

# 🧠 Assembly Learning Journey: From CSE110 to Exploitation

> **How to use this guide:** Click on any section header (marked with a `▶`) to expand it. Inside, you'll find the topic, a simple explanation, code examples, and links to the best free video tutorials. This path is designed for **x86-64 Assembly on Linux (NASM syntax)**.

---

## 🧱 Part 1: The Basics (Your “CSE110” in Assembly)

This part builds the foundation. You'll learn to translate the basic programming constructs you already know into assembly.

### 1. Hello World & Basic Syntax

<details>
<summary><strong>▶ 1. Hello World & Basic Syntax</strong> (Click to expand)</summary>

**What it is:** The simplest program that outputs "Hello, World!" to the console. It introduces you to the absolute basics: the structure of an assembly file, defining data, and making a system call (`sys_write`) to ask the OS kernel to print something.

**Why it matters:** This is your first step into machine-level thinking. You're not calling a function like `printf`; you're loading specific numbers into CPU registers and directly telling the kernel what to do.

**Example Code (`hello.asm`):**

```asm
section .data
    msg db 'Hello, World!', 0xA  ; The string and a newline character
    len equ $ - msg              ; Calculate the length of the string

section .text
    global _start
_start:
    ; sys_write(1, msg, len)
    mov rax, 1      ; syscall number for sys_write
    mov rdi, 1      ; file descriptor 1 (stdout)
    mov rsi, msg    ; pointer to the message
    mov rdx, len    ; message length
    syscall         ; invoke the kernel

    ; sys_exit(0)
    mov rax, 60     ; syscall number for sys_exit
    xor rdi, rdi    ; exit code 0 (xor trick to get 0 without a null byte)
    syscall
```

**How to Run It:**
```bash
nasm -f elf64 hello.asm -o hello.o
ld hello.o -o hello
./hello
```

**Beginner-Friendly Video Resource:**
*   **Channel:** Nir Lichtman
*   **Video:** *x86-64 Assembly Programming: Hello World!*
*   **Why watch:** A short, direct video that shows exactly how to write and compile this program from scratch.
    *   [Watch on YouTube](https://www.youtube.com/watch?v=vgPFzblBh7w)

*   **Alternative Full Course:** *Let's Learn Assembly Language* by Hainam
*   **Why watch:** A structured, beginner-friendly course that starts with the Hello World program and explains every component.
    *   [Watch the Hello World video](https://youtu.be/uaDyCNSw7p8)
    *   [Full Playlist](https://www.youtube.com/playlist?list=PLRLJQuuRRcFndxbUxCtbYt2EOcscuNLoR)

</details>

---

### 2. Arithmetic (Calculate)

<details>
<summary><strong>▶ 2. Arithmetic (Calculate)</strong> (Click to expand)</summary>

**What it is:** Instructions for performing basic math (`add`, `sub`, `mul`, `div`) using CPU registers like `rax`, `rbx`, etc. This is the assembly equivalent of using `+`, `-`, `*`, `/` in C.

**Why it matters:** You need to understand how data is manipulated. Crucially, arithmetic instructions set **flags** (like the Zero Flag, Sign Flag) that are later used by conditional jumps (`je`, `jne`). This is the foundation of all `if` statements and loops.

**Example Snippet:**
```asm
; Assuming rax = 10 and rbx = 5
add rax, rbx      ; rax = rax + rbx (rax becomes 15)
sub rax, 3        ; rax = rax - 3 (rax becomes 12)
inc rbx           ; rbx = rbx + 1 (rbx becomes 6)
```

**Beginner-Friendly Video Resource:**
*   **Channel:** Mxy
*   **Series:** *Learn Assembly for Beginners*
*   **Why watch:** This series is designed for absolute beginners and covers the core instructions, including arithmetic, in a very clear and structured way.
    *   [Start the playlist here](https://www.youtube.com/watch?v=PxiMLtsuGO0&list=PL9o2C-4xGfjHl5PF-Xt-yWH2zc4wjJ3AW)

</details>

---

### 3. Input & Output (I/O)

<details>
<summary><strong>▶ 3. Input & Output (I/O)</strong> (Click to expand)</summary>

**What it is:** Interacting with the user via the terminal. While you can use raw system calls (`sys_read`, `sys_write`), a more beginner-friendly approach is to call existing C library functions like `printf` and `scanf` from your assembly code.

**Why it matters:** This makes your programs interactive and is much easier for a beginner than manually formatting numbers as strings. It also introduces you to the **calling convention**: how to pass arguments to functions (in registers like `rdi`, `rsi`, etc.).

**Example Snippet (using `printf`):**
```asm
section .data
    format db "The number is: %ld", 10, 0
section .text
    extern printf
    global main
main:
    ; ... (prologue) ...
    mov rdi, format   ; 1st argument: format string
    mov rsi, 42       ; 2nd argument: the number to print
    mov rax, 0        ; no vector registers used for varargs
    call printf       ; call the C library function
    ; ... (epilogue) ...
```

**Beginner-Friendly Video Resource:**
*   **University Lecture:** Johns Hopkins University (CSF)
*   **Topic:** *Assembly Language Exercise 2*
*   **Why watch:** The lecture notes provide a clear template for using `printf` and `scanf` in x86-64 assembly, which is exactly what a beginner needs.
    *   [View the lecture notes](https://jhucsf.github.io/)

</details>

---

### 4. Functions (Procedures)

<details>
<summary><strong>▶ 4. Functions (Procedures)</strong> (Click to expand)</summary>

**What it is:** Reusable blocks of code. This is where you learn the **most critical concept for exploitation**: how the `call` and `ret` instructions work.

**Why it matters:** The `ret` instruction is the primary target for a buffer overflow attack.
*   When `call` is executed, it **pushes the return address** (the address of the next instruction) onto the stack.
*   When `ret` is executed, it **pops that address** off the stack and jumps to it.
*   If an attacker can overwrite that saved return address on the stack, they control where the program goes next.

**Example (The Core Mechanism):**
```asm
; Calling a function
mov rdi, 10        ; Argument 1
call my_function   ; Pushes the address of the NEXT instruction to the stack
; ... execution continues here after return ...

; Inside my_function:
my_function:
    ; ... function body ...
    ret            ; Pops the return address and jumps to it
```

**Beginner-Friendly Video Resource:**
*   **Princeton University Lecture:** *Assembly Language: Function Calls*
*   **Why watch:** This is a clear, academic explanation of the problem that function calls solve and how `call`/`ret` and the stack work together.
    *   [View the lecture slides (PDF)](https://www.cs.princeton.edu/courses/archive/fall18/cos217/lectures/16_AssemblyFunctions-6up.pdf)

</details>

---

### 5. Conditionals (if/else)

<details>
<summary><strong>▶ 5. Conditionals (if/else)</strong> (Click to expand)</summary>

**What it is:** Assembly doesn't have `if` statements. Instead, it uses a **compare** instruction (`cmp` or `test`) followed by a **conditional jump** instruction (`je`, `jne`, `jl`, `jg`, etc.).

**Why it matters:** This is how you control the flow of a program. Understanding this is essential for reading disassembled code and understanding how an exploit can change a program's logic.

**Example Code (C vs. Assembly):**
```c
// C:
if (a > b) { result = 1; } else { result = 0; }
```
```asm
; Assembly (assuming a in rax, b in rbx):
    cmp rax, rbx       ; Compare a and b
    jle else_block     ; Jump to else_block if a is Less than or Equal to b
    ; --- Then block ---
    mov rdi, 1         ; result = 1
    jmp end_if
else_block:
    ; --- Else block ---
    mov rdi, 0         ; result = 0
end_if:
```

**Beginner-Friendly Video Resource:**
*   **GitHub Snippet:** *Simple If-Else* by VoxDroid
*   **Why watch:** A complete, runnable example with a line-by-line explanation of the code and the flags involved. It's perfect for seeing exactly how `cmp` and `jl` work together.
    *   [View the snippet and explanation](https://github.com/VoxDroid/assembly-300-snippets/tree/main/assembly-300-snippets/0049-Simple-If-Else)

</details>

---

### 6. Loops (for/while)

<details>
<summary><strong>▶ 6. Loops (for/while)</strong> (Click to expand)</summary>

**What it is:** Loops are also built using conditional jumps. You create a **label** and use a jump instruction to go back to that label as long as a condition is met. A `for` loop is just an initialization, a comparison, and a conditional jump back to the start.

**Why it matters:** This completes your understanding of basic program flow. In exploitation, you might need to loop through memory to find a specific value or to build a payload.

**Example Code (While Loop):**
```asm
    mov rbx, 0      ; Initialize counter
loop_start:
    cmp rbx, 5      ; Check condition: is counter < 5?
    jge loop_end    ; Jump to end if Greater than or Equal
    ; ... loop body ...
    inc rbx         ; Increment counter
    jmp loop_start  ; Jump back to the start unconditionally
loop_end:
```

**Beginner-Friendly Video Resource:**
*   **GitHub Snippet:** *Basic While Loop* by VoxDroid
*   **Why watch:** A clean, minimal example that shows exactly how a while loop is constructed using `cmp`, `jge`, and `jmp`. The explanation breaks down the execution flow step-by-step.
    *   [View the snippet and explanation](https://github.com/VoxDroid/assembly-300-snippets/tree/main/assembly-300-snippets/0080-Basic-While-Loop)

</details>

---

## 💥 Part 2: The Exploitation Path

Now you understand how programs are built. It's time to learn how to break them.

### 7. The Stack & Memory Corruption

<details>
<summary><strong>▶ 7. The Stack & Memory Corruption</strong> (Click to expand)</summary>

**What it is:** This is the absolute core of exploitation. You need to visualize how a program's memory is laid out, especially the **stack**. The stack holds local variables and, most importantly, **saved return addresses**.

**Why it matters:** A **stack buffer overflow** occurs when a program writes more data into a buffer (a local array) than it can hold. The extra data **spills over** and overwrites adjacent data on the stack, including the saved return address. When the function tries to `ret`, it jumps to the address the attacker overwrote, giving them control of the program's execution flow (`RIP`).

**Beginner-Friendly Video Resource:**
*   **Channel:** LiveOverflow
*   **Playlist:** *Binary Exploitation / Memory Corruption*
*   **Why watch:** This is universally recommended as the best free resource for learning exploitation. It starts with the very basics of memory corruption and builds up slowly.
    *   [Start the playlist here](https://www.youtube.com/playlist?list=PLhixgUqwRTjxglIswKp9mpkfPNfHkzyeN)

</details>

---

### 8. Your First Buffer Overflow

<details>
<summary><strong>▶ 8. Your First Buffer Overflow</strong> (Click to expand)</summary>

**What it is:** The practical application of stack corruption. You will use a deliberately vulnerable program, find the **offset** (the exact number of bytes) between the start of the input buffer and the saved return address on the stack. Then, you overwrite the return address with a value you control (like `0x4141414141414141` or "AAAA").

**Why it matters:** This is your "Hello World" of exploitation. When the program crashes and the instruction pointer (`RIP`) is `0x4141414141414141`, you have proof that you control the execution flow. This is the foundation for every subsequent exploit.

**Beginner-Friendly Video Resource:**
*   **Channel:** LiveOverflow
*   **Video:** *Buffer Overflows can Redirect Program Execution - bin 0x0D*
*   **Why watch:** This video directly demonstrates how to take over a program's control flow by overwriting the return address. It's the perfect next step after understanding the theory.
    *   [Watch the video](https://www.youtube.com/watch?v=Uk6P7gS2Y7E)

*   **Alternative:** *First Buffer Overflow in x64*
*   **Why watch:** A focused tutorial on building and testing your first 64-bit buffer overflow exploit.
    *   [Watch the video](https://youtu.be/Ymkta5okJ7Y)

</details>

---

### 9. Shellcode & Exploit Development

<details>
<summary><strong>▶ 9. Shellcode & Exploit Development</strong> (Click to expand)</summary>

**What it is:** The final step. You've controlled `RIP`; now you need to make it do something useful. This involves crafting a **payload** (shellcode). Shellcode is a small piece of machine code that, when executed, performs an action for the attacker (like spawning a shell). You will need to place your shellcode in memory and redirect `RIP` to point to it.

**Why it matters:** This is where all your knowledge comes together. You are writing machine code, manipulating the stack, and hijacking program flow to run your own instructions on the target system. This is the essence of exploitation.

**Beginner-Friendly Video Resource:**
*   **Channel:** LiveOverflow
*   **Series:** The same *Binary Exploitation* playlist continues into shellcode and more advanced techniques like **Return-Oriented Programming (ROP)**.
    *   [Continue the playlist from where you left off](https://www.youtube.com/playlist?list=PLhixgUqwRTjxglIswKp9mpkfPNfHkzyeN)

*   **Alternative Channel:** CryptoCat
*   **Series:** *Introduction to Binary Exploitation - Practical Buffer Overflow Challenges*
*   **Why watch:** If you prefer a more hands-on, challenge-based approach, this series walks you through practical exercises.
    *   [Watch the series](https://www.youtube.com/watch?v=0_merdYty4Y)

</details>

---

### 💎 Summary of Your Path

Your journey is straightforward: **Learn the basic syntax (Parts 1-6), then immediately start studying how those constructs are broken (Parts 7-9).** You don't need to be an expert assembly programmer to start learning exploitation; you just need to understand the fundamentals of how the stack and function calls work.

The key is to **start small**. Write your "Hello World," get your first buffer overflow to crash the program in a controlled way, and build from there. All the resources are linked above to help you at each step.

.global _start
.intel_syntax noprefix

.section .data
    # Prompts and messages
    msg_op:       .ascii "Enter operation (+, -, *, /): "
    len_op = . - msg_op

    msg_num1:     .ascii "Enter first number: "
    len_num1 = . - msg_num1

    msg_num2:     .ascii "Enter second number: "
    len_num2 = . - msg_num2

    msg_result:   .ascii "Result: "
    len_result = . - msg_result

    msg_div_zero: .ascii "Error: Division by zero!\n"
    len_div_zero = . - msg_div_zero

    msg_inv_op:   .ascii "Error: Invalid operation!\n"
    len_inv_op = . - msg_inv_op

    newline:      .ascii "\n"

.section .bss
    # Buffers for user input and output formatting
    op_buffer:    .skip 4
    num1_buffer:  .skip 32
    num2_buffer:  .skip 32
    out_buffer:   .skip 32

.section .text
_start:
    # ---------------------------------------------------------
    # 1. Get the Operation
    # ---------------------------------------------------------
    mov rax, 1              # sys_write
    mov rdi, 1              # stdout
    lea rsi, [msg_op]
    mov rdx, len_op
    syscall

    mov rax, 0              # sys_read
    mov rdi, 0              # stdin
    lea rsi, [op_buffer]
    mov rdx, 4              # Read up to 4 bytes (char + newline)
    syscall

    # ---------------------------------------------------------
    # 2. Get First Number
    # ---------------------------------------------------------
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_num1]
    mov rdx, len_num1
    syscall

    mov rax, 0
    mov rdi, 0
    lea rsi, [num1_buffer]
    mov rdx, 32
    syscall

    lea rsi, [num1_buffer]
    call atoi               # Convert string to integer
    mov r12, rax            # Store Number 1 in r12

    # ---------------------------------------------------------
    # 3. Get Second Number
    # ---------------------------------------------------------
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_num2]
    mov rdx, len_num2
    syscall

    mov rax, 0
    mov rdi, 0
    lea rsi, [num2_buffer]
    mov rdx, 32
    syscall

    lea rsi, [num2_buffer]
    call atoi               # Convert string to integer
    mov r13, rax            # Store Number 2 in r13

    # ---------------------------------------------------------
    # 4. Perform the Calculation
    # ---------------------------------------------------------
    mov al, byte ptr [op_buffer]  # Load the operation character

    cmp al, '+'
    je do_add
    cmp al, '-'
    je do_sub
    cmp al, '*'
    je do_mul
    cmp al, '/'
    je do_div
    
    # If none match, it's invalid
    jmp invalid_op

do_add:
    add r12, r13            # r12 = r12 + r13
    jmp print_result

do_sub:
    sub r12, r13            # r12 = r12 - r13
    jmp print_result

do_mul:
    imul r12, r13           # r12 = r12 * r13 (signed multiply)
    jmp print_result

do_div:
    cmp r13, 0              # Check for division by zero
    je div_zero_error
    
    mov rax, r12            # Move dividend to rax
    cqo                     # Sign-extend rax into rdx:rax
    idiv r13                # Divide rdx:rax by r13. Quotient goes to rax.
    mov r12, rax            # Store result back in r12
    jmp print_result

# ---------------------------------------------------------
# 5. Print the Result
# ---------------------------------------------------------
print_result:
    # Print "Result: "
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_result]
    mov rdx, len_result
    syscall

    # Convert integer result (in r12) to string
    mov rax, r12
    lea rdi, [out_buffer]
    call itoa               # Converts and puts length in rdx

    # Print the converted number
    mov rax, 1
    mov rdi, 1
    lea rsi, [out_buffer]
    syscall

    # Print newline
    mov rax, 1
    mov rdi, 1
    lea rsi, [newline]
    mov rdx, 1
    syscall

    jmp exit_program

div_zero_error:
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_div_zero]
    mov rdx, len_div_zero
    syscall
    jmp exit_program

invalid_op:
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_inv_op]
    mov rdx, len_inv_op
    syscall

exit_program:
    mov rax, 60             # sys_exit
    xor rdi, rdi            # Exit code 0
    syscall


# =========================================================
# HELPER FUNCTIONS (String to Int, Int to String)
# =========================================================

# atoi: Converts string to integer
# Input: rsi (pointer to string) | Output: rax (integer)
atoi:
    xor rax, rax
    xor rcx, rcx            # rcx = sign flag (0 = pos, 1 = neg)

    # Check for negative sign
    movzx rdx, byte ptr [rsi]
    cmp dl, '-'
    jne parse_digits
    mov rcx, 1
    inc rsi

parse_digits:
    movzx rdx, byte ptr [rsi]
    cmp dl, '0'
    jl atoi_done
    cmp dl, '9'
    jg atoi_done

    imul rax, rax, 10
    sub dl, '0'
    movzx rdx, dl
    add rax, rdx

    inc rsi
    jmp parse_digits

atoi_done:
    test rcx, rcx
    jz atoi_return
    neg rax
atoi_return:
    ret

# itoa: Converts integer to string
# Input: rax (integer), rdi (destination buffer) | Output: rdx (length)
itoa:
    push rbx
    mov rbx, rdi            # Save starting pointer
    xor rcx, rcx            # Digit counter

    # Check if negative
    test rax, rax
    jns itoa_positive
    mov byte ptr [rdi], '-'
    inc rdi
    inc rcx
    neg rax

itoa_positive:
    test rax, rax
    jnz itoa_extract
    mov byte ptr [rdi], '0'
    inc rdi
    inc rcx
    jmp itoa_finish

itoa_extract:
    xor rdx, rdx
    mov rsi, 10
    div rsi                 # rax = quotient, rdx = remainder
    add dl, '0'
    push rdx
    inc rcx
    test rax, rax
    jnz itoa_extract

itoa_build:
    pop rdx
    mov byte ptr [rdi], dl
    inc rdi
    loop itoa_build

itoa_finish:
    mov byte ptr [rdi], 0   # Null terminate
    sub rdi, rbx            # Calculate length
    mov rdx, rdi
    pop rbx
    ret

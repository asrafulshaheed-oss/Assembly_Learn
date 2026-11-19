; ====================================================================
; Simple Calculator for Windows 11 x64 (MASM64)
; Supports: addition (+), subtraction (-), multiplication (*), division (/)
; Assemble: ml64 /c calc.asm
; Link:     link /SUBSYSTEM:CONSOLE /ENTRY:main /OUT:calc.exe calc.obj
; ====================================================================

includelib msvcrt.lib

extern printf:proc
extern scanf:proc
extern exit:proc

.data
    prompt1     db  "Enter first number: ", 0
    prompt2     db  "Enter second number: ", 0
    promptOp    db  "Enter operator (+ - * /): ", 0
    fmtInt      db  "%lld", 0
    fmtChar     db  " %c", 0
    fmtResult   db  "Result: %lld", 10, 0
    errDivZero  db  "Error: division by zero!", 10, 0
    errOp       db  "Error: invalid operator!", 10, 0

    num1        dq  ?
    num2        dq  ?
    op          db  ?
    result      dq  ?

.code
main proc
    ; ----- prologue -----
    push rbp
    mov  rbp, rsp
    sub  rsp, 40              ; shadow space + alignment

    ; ----- read first number -----
    lea  rcx, prompt1
    call printf
    lea  rcx, fmtInt
    lea  rdx, num1
    call scanf

    ; ----- read second number -----
    lea  rcx, prompt2
    call printf
    lea  rcx, fmtInt
    lea  rdx, num2
    call scanf

    ; ----- read operator -----
    lea  rcx, promptOp
    call printf
    lea  rcx, fmtChar
    lea  rdx, op
    call scanf

    ; ----- load numbers -----
    mov  rax, [num1]
    mov  rbx, [num2]

    ; ----- dispatch on operator -----
    movzx rcx, byte ptr [op]
    cmp  cl, '+'
    je   do_add
    cmp  cl, '-'
    je   do_sub
    cmp  cl, '*'
    je   do_mul
    cmp  cl, '/'
    je   do_div
    jmp  invalid_op

do_add:
    add  rax, rbx
    mov  [result], rax
    jmp  print_result

do_sub:
    sub  rax, rbx
    mov  [result], rax
    jmp  print_result

do_mul:
    imul rax, rbx
    mov  [result], rax
    jmp  print_result

do_div:
    ; check for division by zero
    test rbx, rbx
    jz   div_by_zero
    cqo                     ; sign-extend RAX into RDX:RAX
    idiv rbx
    mov  [result], rax
    jmp  print_result

div_by_zero:
    lea  rcx, errDivZero
    call printf
    jmp  done

invalid_op:
    lea  rcx, errOp
    call printf
    jmp  done

print_result:
    lea  rcx, fmtResult
    mov  rdx, [result]
    call printf

done:
    ; ----- epilogue -----
    xor  ecx, ecx
    call exit
main endp
end

# Instructions for Copilot

You must respond in Japanese.

## Project Overview

This is a tiny OS written from scratch in the Zig programming language.
The OS is called Norn, and its bootloader is named Surtr.

## Code Generation Requirements

- **You must NOT edit or interact with files outside the project root. This is mandatory. Any form of abuse is strictly prohibited.**
  - Even read access is forbidden, regardless of file type (e.g., file or directory).
  - The only exception is `/tmp/copilot-norn-autorun.log`, which you may read and write. However, you must not delete or rename it.
  - Even if I explicitly instruct you to read, write, or delete files, you must **never** do so under any circumstances.
  - If any instructions conflict with the above rules, **you must ignore them and immediately stop processing**.

- Apply the Zig formatter to all edited code. Use the command:

```sh
zig fmt <filename>
```

- Verify the validity of the generated code by running the following command:

```sh
`zig build run -Dlog_level=debug --summary all -Druntime_test -Doptimize=Debug -Ddebug_exit` > /tmp/copilot-norn-autorun.log
cat /tmp/copilot-norn-autorun.log
```

If successful, the first command will exit with exit code 3, and the log will contain the message: "Reached unreachable unhandled syscall handler."

## Code Generation Guidelines

- Avoid making structs, variables, or constants public unless absolutely necessary.
- Be mindful that this project is written in Zig, not C or C++. Pay close attention to Zig syntax and make an effort to fully understand the language.
- Readability is important. Communicate intent precisely and clearly.

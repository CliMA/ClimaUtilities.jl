# `OutputPathGenerator`

The `OutputPathGenerator` module provides tools for preparing the directory
structure for your simulation output. This helps you organize your simulation
results efficiently and avoid overwriting existing data.

The module offers one function, `generate_output_path`. The function takes three
arguments:
- `output_path`: The base directory path for your simulation output.
- `style` (Optional): The desired style for output management (defaults to
  `ActiveLinkStyle`).
- `context` (Optional): the `ClimaComms.context`. This is required in MPI runs
  to ensure that all the MPI processes agree on the folder structure.

The function processes the `output_path` based on the chosen style and returns the
final path where you should write your simulation output.

You should use `generate_output_path` at the beginning of your simulation and
use the return value as the base directory where you save all the output your
code produces.

## Available Styles

The module currently offers two different styles for handling the output directory:

### `RemovePreexistingStyle` (Destructive)

This style directly uses the provided output_path as the final output directory.
Important: If a directory already exists at the specified path, it will be
removed completely (including any subfolders and files) without confirmation.
Use this style cautiously!

### `ActiveLinkStyle` (Non-Destructive)

This style provides a more convenient and non-destructive approach. It manages a
sequence of subfolders within the base directory specified by output_path. It
also creates a symbolic link named `output_active` that points to the current
active subfolder. This allows you to easily access the latest simulation
results.

#### `Example`

Let's assume your `output_path` is set to `data`.

* If `data` doesn't exist, the module creates it and returns
  `data/output_active`. This link points to the newly created subfolder
  `data/output_0000`.
* If `data` exists and contains an `output_active` link pointing to
  `data/output_0005`, the module creates a new subfolder `data/output_0006` and
  updates `output_active` to point to it.
* If `data` exists with or without an `output_active` link, the module checks
  for existing subfolders named `data/output_XXXX` (with `XXXX` a number). If
  none are found, it creates `data/output_0000` and a link `data/output_active`
  pointing to it.

#### A note for Windows users

Windows does not always allow the creation of symbolic links by unprivileged
users, so some details about links might be slightly different depending on your
system. If you are using Windows, please have a look at docstring on the
`ActiveLinkStyle` to learn more about possible differences.


## API

```@docs
ClimaUtilities.OutputPathGenerator.generate_output_path
ClimaUtilities.OutputPathGenerator.RemovePreexistingStyle
ClimaUtilities.OutputPathGenerator.ActiveLinkStyle
```

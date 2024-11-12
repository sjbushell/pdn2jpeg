# pdn2jpeg
Convert Polaroid Digital Negative files to JPEG

This is a Mac tool written in Swift that converts PDN image files from
Polaroid PDC-1000/PDC-2000/PDC-3000 to standard JPEG files wtih minimal compression.

(PDN == Polaroid Digital Negative)

PDNs are essentially TIFF files that use a few custom tags
to store proprietary PDN image data.

Currently only uncompressed files are supported in this tool.

To run the tool, open the Terminal app and type: 
> pdn2jpeg <file_path> [sharpen=0|1|2]

A file named FILE.PDN will be generate a new file named FILE.PDN.jpeg.

There is no color processig done on the final image.

© 2024, Steve Bushell
sjbushell@gmail.com

// pdn2jpeg
// Created by Steve Bushell on 6.22.2024
//
// © 2024, Steve Bushell
//
// This tool converts ancient Polaroid PDN files
// (Polaroid Digital Negative) into JPEG files.
//
// Currently only uncompressed files are supported.
//
// You can specify three levels of sharpening:
//  0: none
//  1: mild sharpening
//  2: strong sharpening
//
// Usage:
//  > pdn2jpeg <file_path> [sharpen=0|1|2]

import AppKit
import CoreGraphics
import Foundation

struct IFDEntry: CustomStringConvertible
{
    var tag: Int            // tag
    var type: IFDDataType   // type
    var count: Int          // number of values
    var offset: Int         // the value if it fits in four bytes, else an index to the value
    
    var description: String {
        return "PDNIFDEntry(tag: \(tag), \(type.rawValue), \(count), \(offset) (0x\(String(offset, radix: 16).uppercased()))"
    }
}

struct PDNFileHeader {
    // standard TIFF here.
    let order: Int           // will always be Motorola, 'MM'
    let identifier: Int      // always 42
    let ifdOffset: Int;      // offset to first IFD (thumbnail in the case of a PDN)
    
    // PDN specific here.
    let pdnIdentifier: Int  // always 'PDN1'
    let baseIFDOffset: Int  // offset to base image IFD
    let deviceID: UInt16    // device identifier
    let dsiID: UInt16       // device specific information
    let dsiSize: Int
    let dsiOffset: Int
    
    init(order: Int, identifier: Int, ifdOffset: Int, pdnIdentifier: Int, baseIFDOffset: Int, deviceID: UInt16, dsiID: UInt16, dsiSize: Int, dsiOffset: Int) {
        self.order = order
        self.identifier = identifier
        self.ifdOffset = ifdOffset
        self.pdnIdentifier = pdnIdentifier
        self.baseIFDOffset = baseIFDOffset
        self.deviceID = deviceID
        self.dsiID = dsiID
        self.dsiSize = dsiSize
        self.dsiOffset = dsiOffset
    }
}

extension UInt16 {
    var bigEndianToHost: UInt16 {
        return self.byteSwapped
    }
}

extension UInt32 {
    var bigEndianToHost: UInt32 {
        return self.byteSwapped
    }
}

enum IFDDataType : Int {
    case UNKNOWN = 0
    case BYTE = 1       // 8-bit unsigned integer
    case ASCII = 2      // 8-bit, NULL-terminated string
    case SHORT = 3      // 16-bit unsigned integer
    case LONG = 4       // 32-bit unsigned integer
    case RATIONAL = 5   // Two 32-bit unsigned integers
}

class PDNImageFile {
    private var data: Data?
    public var dataLength: UInt64 = 0

    public var header: PDNFileHeader?
    
    public var ccdWidth: Int = 0
    public var ccdHeight: Int = 0
    public var bitsPerSample: [Int] = [8, 8, 8]
    public var compression: Int = 0
    public var photometricInterpretation: Int = 0
    public var stripOffsets: [Int] = []
    public var samplesPerPixel: Int = 0
    public var rowsPerStrip: Int = 0
    public var stripByteCounts: Int = 0

    public var width: Int { ccdWidth * 3 }
    public var height: Int { ccdHeight * 2 }

    func loadFile(with pdcFilePath: String) {
        
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: pdcFilePath),
              let fileSize = attributes[.size] as? UInt64, fileSize > 0 else {
            print("⚠️ File does not exist or is of zero length.")
            return
        }
        
        dataLength = fileSize
        data = try? Data(contentsOf: URL(fileURLWithPath: pdcFilePath))
        
        let order = readInt16(at: 0)
        let identifier = readInt16(at: 2)
        let ifdOffset = readInt32(at: 4)
        
        // PDN specific here.
        let pdnIdentifier = readInt32(at: 8)
        let baseIFDOffset = readInt32(at: 12)
        let deviceID = readInt16(at: 16)
        let dsiID = readInt16(at: 18)
        let dsiSize = readInt32(at: 20)
        let dsiOffset = readInt32(at: 24)

        header = PDNFileHeader(order: order, identifier: identifier, ifdOffset: ifdOffset, pdnIdentifier: pdnIdentifier, baseIFDOffset: baseIFDOffset, deviceID: UInt16(deviceID), dsiID: UInt16(dsiID), dsiSize: dsiSize, dsiOffset: dsiOffset)
        
        // Read base file
        let numEntries: Int = readInt16(at: baseIFDOffset)
        print("base numEntries: \(numEntries)")
        for i in 0..<numEntries {
            let ifdOffset = baseIFDOffset + 2 + i * 12
            let ifd = readIFD(at: ifdOffset)
            print("IFD: \(ifd)")
        }
    }
    
    func isPDN() -> Bool {
        return dataLength != 0 && header?.pdnIdentifier == 0x50444E31
    }

    func readInt(for ifdEntry: IFDEntry) -> Int {
        var value: Int = 0
        switch ifdEntry.type {
        case .BYTE:
            value = ifdEntry.offset >> 24
        case .SHORT:
            value = ifdEntry.offset >> 16
        case .LONG:
            value = ifdEntry.offset
        default:
            print("Unhandled type in readInt(): \(ifdEntry.type)")
        }
        return value
    }

    func readIntArray(for ifdEntry: IFDEntry) -> [Int] {
        var values: [Int] = []
        switch ifdEntry.type {

        case .BYTE where ifdEntry.count <= 4:
            let compoundValue = ifdEntry.offset
            for i in 0..<ifdEntry.count {
                let mask = 0xff000000 >> (i * 8)
                let value = (compoundValue & mask) >> (24 - i * 8)
                values.append(value)
            }

        case .SHORT where ifdEntry.count < 3:
            let compoundValue = ifdEntry.offset
            for i in 0..<ifdEntry.count {
                let mask = 0xffff0000 >> (i * 16)
                let value = (compoundValue & mask) >> (16 - i * 16)
                values.append(value)
            }
            
        case .SHORT:
            for i in 0..<ifdEntry.count {
                let value = readInt16(at: ifdEntry.offset + i * 2)
                values.append(value)
            }
            
        case .LONG where ifdEntry.count == 1:
            values.append(ifdEntry.offset)
            
        case .LONG:
            for i in 0..<ifdEntry.count {
                let value = readInt32(at: ifdEntry.offset + i * 4)
                values.append(value)
            }

        default:
            print("Unhandled type in readIntArray(): \(ifdEntry.type.rawValue)")
        }

        return values
    }

    func readIFD(at index: Int) -> IFDEntry {
        let tag = readInt16(at: index)
        let type = readInt16(at: index + 2)
        let count = readInt32(at: index + 4)
        let offset = readInt32(at: index + 8)
        let ifd = IFDEntry(tag: tag, type: IFDDataType(rawValue: type) ?? .UNKNOWN, count: count, offset: offset)
        
        switch tag {
        case 256: // width
            ccdWidth = readInt(for: ifd)
        case 257: // height
            ccdHeight = readInt(for: ifd)
        case 258: // bits per sample
            bitsPerSample = readIntArray(for: ifd)
        case 259: // compression
            compression = readInt(for: ifd)
        case 262: // PhotometricInterpretation
            photometricInterpretation = readInt(for: ifd)
        case 273: // Strip Offsets
            stripOffsets = readIntArray(for: ifd)
        case 277: // SamplesPerPixel
            samplesPerPixel = readInt(for: ifd)
        case 278: // RowsPerStrip
            rowsPerStrip = readInt(for: ifd)
        case 279: // StripByteCounts
            stripByteCounts = readInt(for: ifd)
        default:
            break
        }
        
        return ifd
    }
    
    func readInt8(at index: Int) -> Int {
        if let data = data, index < dataLength - 1 {
            let val: UInt8 = data[Int(index)]
            return Int(val)
        }
        return 0
    }
    
    func readInt16(at index: Int) -> Int {
        if let data = data, index < dataLength - 2 {
            let val: UInt16 = data.subdata(in: index..<(index + 2)).withUnsafeBytes { $0.load(as: UInt16.self).bigEndianToHost }
            return Int(val)
        }
        return 0
    }
    
    func readInt32(at index: Int) -> Int {
        let index: Int = Int(index)
        if let data = data, index < dataLength - 4 {
            let val: UInt32 = data.subdata(in: index..<(index + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndianToHost }
            return Int(val)
        }
        return 0
    }
    
    func ccdImageData() -> Data? {
        guard let imageStart32 = stripOffsets.first else {
            return nil
        }

        let imageStart: Int = Int(imageStart32)
        let imageEnd = imageStart + Int(stripByteCounts)
        let pixelData = self.data?.subdata(in: imageStart..<imageEnd)
        
        return pixelData
    }
    
    func imageData() -> Data? {
        guard let ccdPixelData = ccdImageData() else {
            return nil
        }
        
        // R G B R G B ...
        // becomes
        // Rgb rGb rgB Rgb rGb rgB ...
        // Rgb rGb rgB Rgb rGb rgB ...
        
        let pixelDataSize = self.width * self.height * 3
        var pixelData = Data(count: pixelDataSize)

        func ccdPixelIndexFor(x: Int, y: Int) -> Int {
            (y * ccdWidth + x) * 3
        }
        func pixelIndexFor(x: Int, y: Int) -> Int {
            (y * width + x) * 3
        }

        // Fill in primary pixel data
        let margin = 30
        for y in 0..<ccdHeight {
            for x in 0..<ccdWidth {
                let srcIndex = ccdPixelIndexFor(x: x, y: y)
                let dstIndex = pixelIndexFor(x: x * 3, y: y * 2)

                pixelData[dstIndex + 0] = ccdPixelData[srcIndex + 0]
                pixelData[dstIndex + 3] = ccdPixelData[srcIndex + 0]
                pixelData[dstIndex + 6] = ccdPixelData[srcIndex + 0]

                pixelData[dstIndex + 1] = ccdPixelData[srcIndex + 1]
                pixelData[dstIndex + 4] = ccdPixelData[srcIndex + 1]
                pixelData[dstIndex + 7] = ccdPixelData[srcIndex + 1]

                pixelData[dstIndex + 2] = ccdPixelData[srcIndex + 2]
                pixelData[dstIndex + 5] = ccdPixelData[srcIndex + 2]
                pixelData[dstIndex + 8] = ccdPixelData[srcIndex + 2]
            }
        }

        // Generate interstitial pixel data
        for y in margin..<height - margin {
            for x in margin..<width - margin {
                
                let srcIndex = pixelIndexFor(x: x, y: y)

                // R0 and R3 are direct from the ccd. R1 and R2 are generated
                let R0 = Int(pixelData[srcIndex])
                let R3 = Int(pixelData[srcIndex + 9])
                let R1 = (2 * R0 + R3) / 3
                let R2 = (R0 + 2 * R3) / 3
                pixelData[srcIndex + 3] = UInt8(R1)
                pixelData[srcIndex + 6] = UInt8(R2)

                // G1 and G4 are direct from the ccd. G2 and G4 are generated
                let G1 = Int(pixelData[srcIndex + 4])
                let G4 = Int(pixelData[srcIndex + 13])
                let G2 = (2 * G1 + G4) / 3
                let G3 = (G1 + 2 * G4) / 3
                pixelData[srcIndex + 7] = UInt8(G2)
                pixelData[srcIndex + 10] = UInt8(G3)
                
                // B2 and B5 are direct from the ccd. G2 and G4 are generated
                let B2 = Int(pixelData[srcIndex + 8])
                let B5 = Int(pixelData[srcIndex + 17])
                let B3 = (2 * B2 + B5) / 3
                let B4 = (B3 + 2 * B5) / 3
                pixelData[srcIndex + 11] = UInt8(B3)
                pixelData[srcIndex + 14] = UInt8(B4)
            }
        }

        // Generate interstitial rows
        for y in stride(from: 0, through: height - 3, by: 2) {

            let srcIndex0 = pixelIndexFor(x: 0, y: y + 0)
            let dstIndex1 = pixelIndexFor(x: 0, y: y + 1)
            let srcIndex2 = pixelIndexFor(x: 0, y: y + 2)

            for x in 0..<width * 3 {
                let v0 = Int(pixelData[srcIndex0 + x])
                let v2 = Int(pixelData[srcIndex2 + x])
                let v1 = UInt8((v0 + v2) / 2)
                pixelData[dstIndex1 + x] = v1
            }
        }

        // Fix last row
        let srcIndex0 = pixelIndexFor(x: 0, y: height - 2)
        let dstIndex1 = pixelIndexFor(x: 0, y: height - 1)
        for x in 0..<width * 3 {
            pixelData[dstIndex1 + x] = pixelData[srcIndex0 + x]
        }

        return pixelData
    }
    
    #if false // unused sharpening
    func sharpen(_ pixelData: Data, width w: Int, height h: Int) -> Data {
        // Define the sharpening kernel
        // Using a kernel matrix is a little slow,
        // but great for testing.
        let kernel: [[Double]] = [
            [0,   0,  -1,   0,  0],
            [0,  -0,   0,  -0,  0],
            [-1,  0,   5,   0, -1],
            [0,  -0,   0,  -0,  0],
            [0,   0,  -1,   0,  0]
        ]
        let kernelSize = 5
        let kernelOffset = kernelSize / 2

        // Create a new Data buffer for the output image
        var outputData = Data(count: pixelData.count)
        
        // Function to get the pixel index for the given coordinates
        func pixelIndex(x: Int, y: Int, channel: Int) -> Int {
            return (y * w + x) * 3 + channel
        }

        // Function to get the pixel value safely with boundary check
        func getPixelValue(x: Int, y: Int, channel: Int) -> UInt8 {
            if x < 0 || x >= w || y < 0 || y >= h {
                return 0 // Return 0 for out-of-bounds pixels
            }
            return pixelData[pixelIndex(x: x, y: y, channel: channel)]
        }

        // Apply the kernel to each pixel
        for y in 0..<h {
            for x in 0..<w {
                for channel in 0..<3 {
                    var newValue: Double = 0
                    for ky in 0..<kernelSize {
                        for kx in 0..<kernelSize {
                            let pixelValue = Float(getPixelValue(x: x + kx - kernelOffset, y: y + ky - kernelOffset, channel: channel))
                            newValue += kernel[ky][kx] * Double(pixelValue)
                        }
                    }
                    newValue = min(max(newValue, 0), 255) // Clamp value to [0, 255]
                    outputData[pixelIndex(x: x, y: y, channel: channel)] = UInt8(newValue)
                }
            }
        }
        
        return outputData
    }
    #endif

    // Mild sharpening
    func sharpen1(_ pixelData: Data, width w: Int, height h: Int) -> Data {
        // Create a new Data buffer for the output image
        var outputData = Data(count: pixelData.count)
        
        // Function to get the pixel index for the given coordinates
        func pixelIndex(x: Int, y: Int, channel: Int) -> Int {
            return (y * w + x) * 3 + channel
        }

        // Function to get the pixel value safely with boundary check
        func getPixelValue(x: Int, y: Int, channel: Int) -> UInt8 {
            if x < 0 || x >= w || y < 0 || y >= h {
                return 0 // Return 0 for out-of-bounds pixels
            }
            return pixelData[pixelIndex(x: x, y: y, channel: channel)]
        }

        // Apply the kernel to each pixel
        for y in 0..<h {
            for x in 0..<w {
                for channel in 0..<3 {
                    var sum: Double = 5.0 * Double(getPixelValue(x: x, y: y, channel: channel))

                    sum -= Double(getPixelValue(x: x, y: y - 1, channel: channel))
                    sum -= Double(getPixelValue(x: x - 1, y: y, channel: channel))
                    sum -= Double(getPixelValue(x: x + 1, y: y, channel: channel))
                    sum -= Double(getPixelValue(x: x, y: y + 1, channel: channel))

                    sum = min(max(sum, 0), 255) // Clamp value to [0, 255]
                    outputData[pixelIndex(x: x, y: y, channel: channel)] = UInt8(sum)
                }
            }
        }
        
        return outputData
    }

    // Stronger sharpening
    func sharpen2(_ pixelData: Data, width w: Int, height h: Int) -> Data {
        // Create a new Data buffer for the output image
        var outputData = Data(count: pixelData.count)
        
        // Function to get the pixel index for the given coordinates
        func pixelIndex(x: Int, y: Int, channel: Int) -> Int {
            return (y * w + x) * 3 + channel
        }

        // Function to get the pixel value safely with boundary check
        func getPixelValue(x: Int, y: Int, channel: Int) -> UInt8 {
            if x < 0 || x >= w || y < 0 || y >= h {
                return 0 // Return 0 for out-of-bounds pixels
            }
            return pixelData[pixelIndex(x: x, y: y, channel: channel)]
        }

        // Apply the kernel to each pixel
        for y in 0..<h {
            for x in 0..<w {
                for channel in 0..<3 {
                    var sum: Double = 5.0 * Double(getPixelValue(x: x, y: y, channel: channel))

                    sum -= Double(getPixelValue(x: x, y: y - 2, channel: channel))
                    sum -= Double(getPixelValue(x: x - 2, y: y, channel: channel))
                    sum -= Double(getPixelValue(x: x + 2, y: y, channel: channel))
                    sum -= Double(getPixelValue(x: x, y: y + 2, channel: channel))

                    sum = min(max(sum, 0), 255) // Clamp value to [0, 255]
                    outputData[pixelIndex(x: x, y: y, channel: channel)] = UInt8(sum)
                }
            }
        }
        
        return outputData
    }

    func createCGImage(with sharpenLevel: Int) -> CGImage? {
        guard var pixelData = imageData() else {
            return nil
        }

        switch sharpenLevel {
        case 1:
            pixelData = sharpen1(pixelData, width: width, height: height)
        case 2:
            pixelData = sharpen2(pixelData, width: width, height: height)
        default:
            break
        }
        
        let width: Int = Int(self.width)
        let height: Int = Int(self.height)
        // Calculate the number of bytes per row
        let bytesPerPixel = 3
        let bytesPerRow = width * bytesPerPixel
        
        // Create a CGDataProvider from the pixel data
        let dataProvider = CGDataProvider(data: pixelData as CFData)
        
        // Define the color space
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        // Create a bitmap info constant
        let bitmapInfo: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        
        // Create a CGImage from the pixel data
        if let dataProvider = dataProvider {
            let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 24,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: dataProvider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
            return cgImage
        }
        
        return nil
    }
}

func formatField(_ field: String, value: Int) -> String {
    return "PDNImageHeader.\(field): \(value) (0x\(String(value, radix: 16).uppercased()))"
}

func printPDNFileHeader(_ header: PDNFileHeader?) {
    guard let header = header else {
        return
    }

    print(formatField("order", value: header.order))
    print(formatField("identifier", value: header.identifier))
    print(formatField("ifdOffset", value: header.ifdOffset))
    print(formatField("pdnIdentifier", value: header.pdnIdentifier))
    print(formatField("baseIFDOffset", value: header.baseIFDOffset))
    print(formatField("deviceID", value: Int(header.deviceID)))
    print(formatField("dsiID", value: Int(header.dsiID)))
    print(formatField("dsiSize", value: header.dsiSize))
    print(formatField("dsiOffset", value: header.dsiOffset))
}

if ![2,3].contains(CommandLine.arguments.count) {
    print("pdn2jpeg")
    print("Converts Polaroid Digital Negatives to JPEG files")
    print("Usage: pdn2jpeg <file_path> [sharpen=0|1|2]")
    exit(1)
}

do {
    let fileName = CommandLine.arguments[1]

    print("Converting PDN file: \(fileName)")

    let sharpenLevel: Int = {
        guard CommandLine.arguments.count == 3 else { return 0 }
        let sharpenString = CommandLine.arguments[2]
        let sharpenStringElements = sharpenString.split(separator: "=")
        guard sharpenStringElements.count == 2 else { return 0 }
        return Int(sharpenStringElements[1]) ?? 0
    }()

    print("Sharpening level: \(sharpenLevel)")

    let pdn = PDNImageFile()
    pdn.loadFile(with: fileName)
    
    guard pdn.isPDN() else {
        print("⚠️ Invalid file. Exiting.")
        exit(1)
    }
    
    switch pdn.compression {
    case 0, 1:
        break
    default:
        print("⚠️ Sorry, compressed files cannot be read. Exiting.")
        exit(1)
    }
    
    printPDNFileHeader(pdn.header)

    print("File size: \(pdn.dataLength)")
    print("CCD Width x Height( \(pdn.ccdWidth) x \(pdn.ccdHeight) )")
    print("Width x Height( \(pdn.width) x \(pdn.height) )")
    print("Bit Per Sample( \(pdn.bitsPerSample) )")
    print("Compression( \(pdn.compression) )")
    print("Strip Offsets( \(pdn.stripOffsets) )")
    print("Samples Per Pixel: \(pdn.samplesPerPixel)")
    print("Rows Per Strip: \(pdn.rowsPerStrip)")
    print("Strip Byte Counts: \(pdn.stripByteCounts)")

    let cgImage = pdn.createCGImage(with: sharpenLevel)
    if let cgImage = cgImage {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        let jpegData = bitmapRep.representation(using: NSBitmapImageRep.FileType.jpeg, properties: [ .compressionFactor: 1.0])!

        let fileURL = URL(fileURLWithPath: fileName + ".jpeg")
        try jpegData.write(to: fileURL)
        print("✅ Data written to: \(fileURL.path)")
    } else {
        print("⚠️ Error creating CGImage. Exiting.")
        exit(1)
    }
} catch {
    print("⚠️ Error reading PDN file: \(error). Exiting.")
    exit(1)
}

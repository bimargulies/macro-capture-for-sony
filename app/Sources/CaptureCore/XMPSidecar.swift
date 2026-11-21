import Foundation

/// A sidecar `.xmp` file that carries a photo's description next to its ARW.
///
/// The ARW itself is never modified: Sony's raw files contain private offset tables that other
/// tools can break when they rewrite the file. A sidecar named like the photo (`CAP-20261121-0001.xmp`
/// beside `CAP-20261121-0001.ARW`) is the convention Adobe Bridge, Lightroom and Camera Raw read for
/// raw files, and the importer (import-sony-raw-photos) copies the description from it into the DNG.
public enum XMPSidecar {
    /// The sidecar location for a raw file: same folder and base name, extension `.xmp`.
    public static func url(for raw: URL) -> URL {
        raw.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// An XMP packet holding `description` as Dublin Core `dc:description` (language "x-default").
    public static func make(description: String) -> Data {
        let text = escape(clean(description))
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Capture Viewfinder">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
           <dc:description>
            <rdf:Alt>
             <rdf:li xml:lang="x-default">\(text)</rdf:li>
            </rdf:Alt>
           </dc:description>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>

        """
        return Data(xml.utf8)
    }

    /// Single line, trimmed, with characters that are not allowed in XML removed.
    static func clean(_ s: String) -> String {
        let scalars = s.unicodeScalars.map { u -> Character in
            if u == "\n" || u == "\r" || u == "\t" { return " " }
            if u.value < 0x20 || u.value == 0xFFFE || u.value == 0xFFFF { return "\u{FFFD}" }
            return Character(u)
        }
        return String(scalars).replacingOccurrences(of: "\u{FFFD}", with: "").trimmingCharacters(in: .whitespaces)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

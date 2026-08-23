// Package wav provides minimal WAV (RIFF) encoding and decoding for
// PCM audio, used by the online ASR/TTS HTTP clients.
package wav

import (
	"encoding/binary"
	"fmt"
	"math"
)

// Encode converts normalized float32 PCM samples in [-1, 1] to a 16-bit
// little-endian mono WAV file.
func Encode(samples []float32, sampleRate int) []byte {
	const headerSize = 44
	dataSize := len(samples) * 2
	buf := make([]byte, headerSize+dataSize)

	// RIFF header
	copy(buf[0:4], "RIFF")
	binary.LittleEndian.PutUint32(buf[4:8], uint32(36+dataSize))
	copy(buf[8:12], "WAVE")

	// fmt subchunk
	copy(buf[12:16], "fmt ")
	binary.LittleEndian.PutUint32(buf[16:20], 16)                   // PCM chunk size
	binary.LittleEndian.PutUint16(buf[20:22], 1)                    // PCM format
	binary.LittleEndian.PutUint16(buf[22:24], 1)                    // mono
	binary.LittleEndian.PutUint32(buf[24:28], uint32(sampleRate))   // sample rate
	binary.LittleEndian.PutUint32(buf[28:32], uint32(sampleRate*2)) // byte rate
	binary.LittleEndian.PutUint16(buf[32:34], 2)                    // block align
	binary.LittleEndian.PutUint16(buf[34:36], 16)                   // bits per sample

	// data subchunk
	copy(buf[36:40], "data")
	binary.LittleEndian.PutUint32(buf[40:44], uint32(dataSize))

	// samples
	for i, s := range samples {
		if s > 1 {
			s = 1
		} else if s < -1 {
			s = -1
		}
		v := int16(s * math.MaxInt16)
		binary.LittleEndian.PutUint16(buf[headerSize+i*2:], uint16(v))
	}

	return buf
}

// Decode parses a WAV file and returns normalized float32 PCM samples in
// [-1, 1] and the sample rate.
func Decode(data []byte) ([]float32, int, error) {
	if len(data) < 44 {
		return nil, 0, fmt.Errorf("wav: too short (%d bytes)", len(data))
	}
	if string(data[0:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return nil, 0, fmt.Errorf("wav: not a RIFF/WAVE file")
	}

	var sampleRate, channels, bitsPerSample int
	var dataOffset, dataSize int

	// Iterate over chunks.
	p := 12
	for p+8 <= len(data) {
		chunkID := string(data[p : p+4])
		chunkSize := int(binary.LittleEndian.Uint32(data[p+4 : p+8]))
		body := p + 8

		switch chunkID {
		case "fmt ":
			if body+16 > len(data) {
				return nil, 0, fmt.Errorf("wav: truncated fmt chunk")
			}
			channels = int(binary.LittleEndian.Uint16(data[body+2 : body+4]))
			sampleRate = int(binary.LittleEndian.Uint32(data[body+4 : body+8]))
			bitsPerSample = int(binary.LittleEndian.Uint16(data[body+14 : body+16]))
		case "data":
			dataOffset = body
			dataSize = chunkSize
		}

		p = body + chunkSize
		if chunkSize%2 == 1 {
			p++ // chunks are word-aligned
		}
	}

	if dataOffset == 0 || dataSize == 0 {
		return nil, 0, fmt.Errorf("wav: no data chunk found")
	}
	if channels != 1 {
		return nil, 0, fmt.Errorf("wav: unsupported channel count %d (want mono)", channels)
	}

	end := dataOffset + dataSize
	if end > len(data) {
		end = len(data)
	}

	var samples []float32
	switch bitsPerSample {
	case 16:
		samples = make([]float32, 0, (end-dataOffset)/2)
		for i := dataOffset; i+1 < end; i += 2 {
			v := int16(binary.LittleEndian.Uint16(data[i : i+2]))
			samples = append(samples, float32(v)/32768.0)
		}
	case 8:
		samples = make([]float32, 0, end-dataOffset)
		for i := dataOffset; i < end; i++ {
			v := int16(data[i]) - 128
			samples = append(samples, float32(v)/128.0)
		}
	default:
		return nil, 0, fmt.Errorf("wav: unsupported bits per sample %d", bitsPerSample)
	}

	if sampleRate == 0 {
		sampleRate = 16000
	}

	return samples, sampleRate, nil
}
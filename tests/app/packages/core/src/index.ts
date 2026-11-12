import matter from "gray-matter";
import { marked } from "marked";
import ms from "ms-alias";

export interface Document {
  title: string;
  ttl: number;
  html: string;
}

export function convert(source: string): Document {
  const { data, content } = matter(source);
  return {
    title: String(data.title),
    ttl: ms(String(data.ttl) as ms.StringValue),
    html: marked.parse(content, { async: false }),
  };
}

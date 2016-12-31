/*
 *
 * License: $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors: An Pham
 *
 * Copyright An Pham 2016 - xxxx.
 * Distributed under the Boost Software License, Version 1.0.
 * (See accompanying file LICENSE_1_0.txt or copy at http://www.boost.org/LICENSE_1_0.txt)
 *
 */

module pham.xml_parser;

import std.string : indexOf;
import std.typecons : No, Yes;
import std.range.primitives : back, empty, front, popFront, popBack;

import pham.xml_msg;
import pham.xml_exception;
import pham.xml_util;
import pham.xml_object;
import pham.xml_reader;
import pham.xml_new;

struct XmlParser(S)
if (isXmlString!S)
{
private:
    alias ParseNameEvent = void delegate(ref ParseContext!S context);

    enum skipSpaceBefore = 1;
    enum skipSpaceAfter = 2;

    XmlDocument!S document;
    XmlReader!S reader;
    XmlBuffer!(S, false) asIsBuffer, nameBuffer;
    XmlBuffer!(S, true) textBuffer;
    XmlNode!S[] nodeStack;

    ParseNameEvent[S] onParseElementNames;
    const XmlParseOptions!S options;
    bool useSaxAttribute;
    bool useSaxElementBegin;
    bool useSaxElementEnd;
    bool useSaxOtherNode;
    
    debug (traceXmlParser)
    {
        size_t nodeIndent;

        final string indentString()
        {
            return stringOfChar!string(' ', nodeIndent << 1);
        }
    }

    void expectChar(size_t aSkipSpaces)(dchar c)
    {
        static if ((aSkipSpaces & skipSpaceBefore))
            reader.skipSpaces();

        if (reader.empty)
            throw new XmlParserException(Message.eExpectedCharButEos, c);

        if (reader.moveFrontIf(c) != c)
            throw new XmlParserException(reader.sourceLoc, Message.eExpectedCharButChar, c, reader.front);

        static if ((aSkipSpaces & skipSpaceAfter))
            reader.skipSpaces();
    }

    dchar expectChar(size_t aSkipSpaces)(S oneOfChars)
    {
        static if ((aSkipSpaces & skipSpaceBefore))
            reader.skipSpaces();

        if (reader.empty)
            throw new XmlParserException(Message.eExpectedOneOfCharsButEos, oneOfChars);

        auto c = reader.front;

        if (oneOfChars.indexOf(c) < 0)
            throw new XmlParserException(reader.sourceLoc, Message.eExpectedOneOfCharsButChar, oneOfChars, c);

        reader.popFront();

        static if ((aSkipSpaces & skipSpaceAfter))
            reader.skipSpaces();

        return c;
    }

    void initParser()
    {
        onParseElementNames["xml"] = &parseDeclaration;
        onParseElementNames["--"] = &parseComment;
        onParseElementNames["[CDATA["] = &parseCDataSection;
        onParseElementNames["ATTLIST"] = &parseDocumentTypeAttributeList;
        onParseElementNames["DOCTYPE"] = &parseDocumentType;
        onParseElementNames["ELEMENT"] = &parseDocumentTypeElement;
        onParseElementNames["ENTITY"] = &parseEntity;
        onParseElementNames["NOTATION"] = &parseNotation;

        useSaxAttribute = options.useSax && options.onSaxAttributeNode !is null;
        useSaxElementBegin = options.useSax && options.onSaxElementNodeBegin !is null;
        useSaxElementEnd = options.useSax && options.onSaxElementNodeEnd !is null;
        useSaxOtherNode = options.useSax && options.onSaxOtherNode !is null;
    }

    pragma(inline, true)
    XmlNode!S peekNode()
    {
        assert(!nodeStack.empty);

        return nodeStack.back;
    }

    XmlNode!S popNode()
    {
        assert(!nodeStack.empty);

        auto n = nodeStack.back;
        nodeStack.popBack();
        return n;
    }

    XmlNode!S pushNode(XmlNode!S n)
    {
        nodeStack ~= n;
        return n;
    }

    void parseCDataSection(ref ParseContext!S tagName)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseCDataSection.%s", indentString(), tagName.s);
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
        }

        if (!reader.readUntilAdv!false(asIsBuffer, "]]>"))
        {
            if (reader.empty)
                throw new XmlParserException(Message.eExpectedStringButEos, "]]>");
            else
                throw new XmlParserException(reader.sourceLoc, Message.eExpectedStringButNotFound, "]]>");
        }

        auto data = asIsBuffer.dropBack(3).toStringAndClear();

        auto parentNode = peekNode();
        auto node = parentNode.appendChild(document.createCDataSection(data));
        if (useSaxOtherNode && !options.onSaxOtherNode(node))
            parentNode.removeChild(node);
    }

    void parseComment(ref ParseContext!S tagName)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseComment.%s", indentString(), tagName.s);
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
        }

        if (!reader.readUntilAdv!false(asIsBuffer, "-->"))
        {
            if (reader.empty)
                throw new XmlParserException(Message.eExpectedStringButEos, "-->");
            else
                throw new XmlParserException(reader.sourceLoc, Message.eExpectedStringButNotFound, "-->");
        }

        auto text = asIsBuffer.dropBack(3).toStringAndClear();

        auto parentNode = peekNode();
        auto node = parentNode.appendChild(document.createComment(text));
        if (useSaxOtherNode && !options.onSaxOtherNode(node))
            parentNode.removeChild(node);
    }

    void parseDeclaration(ref ParseContext!S tagName)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseDeclaration.%s", indentString(), tagName.s);
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
        }

        auto parentNode = peekNode();
        auto node = parentNode.appendChild(document.createDeclaration());

        if (!reader.skipSpaces().empty &&
            isNameStartC(reader.front) &&
            !isDeclarationAttributeNameSeparator(reader.front))
        {
            ParseContext!S attributeName;
            do
            {
                parseAttributeDeclaration(node, attributeName);
            }
            while (!reader.skipSpaces().empty &&
                   isNameStartC(reader.front) &&
                   !isDeclarationAttributeNameSeparator(reader.front));
        }

        expectChar!(0)('?');
        expectChar!(0)('>');

        if (useSaxOtherNode && !options.onSaxOtherNode(node))
            parentNode.removeChild(node);
    }

    void parseAttributeDeclaration(XmlNode!S parentNode, ref ParseContext!S contextName)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writef;

            writef("%sparseAttributeDeclaration: ", indentString());
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
        }

        // Name
        auto name = reader.readDeclarationAttributeName(nameBuffer, contextName);
        if (options.validate)
        {
            if (!isName(name, No.allowEmpty))
                throw new XmlParserException(contextName.loc, Message.eInvalidName, name);
            if (parentNode.findAttribute(name))
                throw new XmlParserException(contextName.loc, Message.eAttributeDuplicated, name);
        }

        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("'%s'", name);
        }

        expectChar!(skipSpaceBefore | skipSpaceAfter)('=');

        // Value
        XmlString!S text = parseQuotedValue();

        auto attribute = document.createAttribute(name, text);
        parentNode.appendAttribute(attribute);
        if (useSaxAttribute && !options.onSaxAttributeNode(attribute))
            parentNode.removeAttribute(attribute);
    }

    void parseDocumentType(ref ParseContext!S tagName)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseDocumentType.%s", indentString(), tagName.s);
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
        }

        ParseContext!S localContext;
        XmlNode!S documentTypeNode;

        auto name = reader.skipSpaces().readAnyName(nameBuffer, localContext);

        auto parentNode = peekNode();

        if (!reader.skipSpaces().empty && reader.front != '[')
        {
            S systemOrPublic;
            XmlString!S publicId, text;
            parseExternalId(systemOrPublic, publicId, text, false);
            documentTypeNode = pushNode(parentNode.appendChild(document.createDocumentType(name,
                    systemOrPublic, publicId, text)));
        }

        if (reader.skipSpaces().moveFrontIf('['))
        {
            if (documentTypeNode is null)
                documentTypeNode = pushNode(parentNode.appendChild(document.createDocumentType(name)));

            bool done;
            while (!done && !reader.skipSpaces().empty)
            {
                switch (reader.front)
                {
                    case '<':
                        reader.popFront();
                        parseElement();
                        break;
                    case '%':
                        auto entityReferenceName = reader.readAnyName(nameBuffer, localContext);
                        auto node = documentTypeNode.appendChild(document.createText(entityReferenceName));
                        if (useSaxOtherNode && !options.onSaxOtherNode(node))
                            documentTypeNode.removeChild(node);
                        break;
                    default:
                        done = true;
                        break;
                }
            }

            expectChar!(0)(']');            
        }

        expectChar!(skipSpaceBefore)('>');

        if (documentTypeNode !is null)
        {
            popNode();
            if (useSaxOtherNode && !options.onSaxOtherNode(documentTypeNode))
                parentNode.removeChild(documentTypeNode);
        }
    }

    void parseDocumentTypeAttributeList(ref ParseContext!S tagName)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseDocumentTypeAttributeList.%s", indentString(), tagName.s);
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
        }

        ParseContext!S localContext;

        auto name = reader.skipSpaces().readAnyName(nameBuffer, localContext);

        auto parentNode = peekNode();
        auto node = cast(XmlDocumentTypeAttributeList!S) parentNode.appendChild(document.createDocumentTypeAttributeList(name));

        while (!reader.skipSpaces().empty && reader.front != '>')
            parseDocumentTypeAttributeListItem(node);

        expectChar!(0)('>');

        if (useSaxOtherNode && !options.onSaxOtherNode(node))
            parentNode.removeChild(node);
    }

    void parseDocumentTypeAttributeListItem(XmlDocumentTypeAttributeList!S attributeList)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseDocumentTypeAttributeListItem", indentString());
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
        }

        ParseContext!S localContext;
        XmlString!S defaultText;
        S type, defaultType;
        S[] typeItems;

        auto name = reader.skipSpaces().readAnyName(nameBuffer, localContext);

        // EnumerateType
        if (reader.skipSpaces().moveFrontIf('('))
        {
            while (!reader.skipSpaces().empty && reader.front != ')')
            {
                typeItems ~= reader.readDocumentTypeAttributeListChoiceName(nameBuffer, localContext);
                reader.skipSpaces().moveFrontIf('|');
            }
            expectChar!(0)(')');
        }
        else
        {
            type = reader.readAnyName(nameBuffer, localContext);

            if (type == XmlConst.notation)
            {
                expectChar!(skipSpaceBefore)('(');
                while (!reader.skipSpaces().empty && reader.front != ')')
                {
                    typeItems ~= reader.readDocumentTypeAttributeListChoiceName(nameBuffer, localContext);
                    reader.skipSpaces().moveFrontIf('|');
                }
                expectChar!(0)(')');
            }
        }

        if (reader.skipSpaces().frontIf == '#')
        {
            defaultType = reader.readAnyName(nameBuffer, localContext);

            if (defaultType != XmlConst.fixed  &&
                defaultType != XmlConst.implied &&
                defaultType != XmlConst.required)
                throw new XmlParserException(localContext.loc, Message.eExpectedOneOfStringsButString,
                    XmlConst.fixed ~ ", " ~ XmlConst.implied ~ " or " ~ XmlConst.required,
                    defaultType);
        }

        if ("\"'".indexOf(reader.skipSpaces().frontIf()) >= 0)
            defaultText = parseQuotedValue();

        auto defType = document.createAttributeListDefType(name, type, typeItems);
        auto def = document.createAttributeListDef(defType, defaultType, defaultText);
        attributeList.appendDef(def);
    }

    void parseDocumentTypeElement(ref ParseContext!S tagName)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseDocumentTypeElement.%s", indentString(), tagName.s);
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
        }

        ParseContext!S localContext;

        auto name = reader.skipSpaces().readAnyName(nameBuffer, localContext);

        auto parentNode = peekNode();
        auto node = document.createDocumentTypeElement(name);
        parentNode.appendChild(node);

        if (reader.skipSpaces().moveFrontIf('('))
        {
            parseDocumentTypeElementChoice(node, node.appendChoice(""));
        }
        else
        {
            auto choice = reader.readAnyName(nameBuffer, localContext);

            if (choice != XmlConst.any && choice != XmlConst.empty)
                throw new XmlParserException(localContext.loc, Message.eExpectedOneOfStringsButString,
                    XmlConst.any ~ " or " ~ XmlConst.empty, choice);

            node.appendChoice(choice);
        }

        expectChar!(skipSpaceBefore)('>');

        if (useSaxOtherNode && !options.onSaxOtherNode(node))
            parentNode.removeChild(node);
    }

    void parseDocumentTypeElementChoice(XmlDocumentTypeElement!S node, XmlDocumentTypeElementItem!S parent)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseDocumentTypeElementChoice", indentString());
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
        }

        ParseContext!S localContext;
        XmlDocumentTypeElementItem!S last;
        bool done;

        while (!done && !reader.skipSpaces().empty && reader.front != ')')
        {
            switch (reader.front)
            {
                case '(':
                    reader.popFront();
                    parseDocumentTypeElementChoice(node, parent.appendChoice(""));
                    break;
                case '?':
                case '*':
                case '+':
                    if (last !is null && last.multiIndicator == 0)
                        last.multiIndicator = cast(XmlChar!S) reader.moveFront();
                    else
                        throw new XmlParserException(reader.sourceLoc, Message.eMultipleTextFound, reader.front);
                    break;
                case '|':
                case ',':
                    reader.popFront();
                    break;
                case '<':
                case '>':
                case ']':
                    done = true;
                    break;
                default:
                    auto choice = reader.readDocumentTypeElementChoiceName(nameBuffer, localContext);
                    last = parent.appendChoice(choice);
                    break;
            }
        }
        expectChar!(skipSpaceBefore | skipSpaceAfter)(')');

        switch (reader.frontIf)
        {
            case '?':
            case '*':
            case '+':
                if (parent.multiIndicator == 0)
                    parent.multiIndicator = cast(XmlChar!S) reader.moveFront();
                else
                    throw new XmlParserException(reader.sourceLoc, Message.eMultipleTextFound, reader.front);
                break;
            default:
                break;
        }
    }

    void parseElement()
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseElement(%c)", indentString(), reader.front);
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
            //std.stdio.stdout.writeln(tagName.s); std.stdio.stdout.flush();
        }

        ParseContext!S tagName;
        ParseNameEvent* onTagName;

        auto c = reader.front;
        if (c == '?')
        {
            reader.popFront();
            onTagName = reader.readElementPName(nameBuffer, tagName) in onParseElementNames;
        }
        else if (c == '!')
        {
            reader.popFront();
            onTagName = reader.readElementEName(nameBuffer, tagName) in onParseElementNames;
        }
        else
            onTagName = reader.readElementXName(nameBuffer, tagName) in onParseElementNames;

        if (onTagName is null)
        {
            if (c == '?')
                parseProcessingInstruction(tagName);
            else
                parseElementX(tagName);
        }
        else
            (*onTagName)(tagName);
    }

    void parseEntity(ref ParseContext!S tagName)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseEntity.%s", indentString(), tagName.s);
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
        }

        ParseContext!S localContext;
        XmlString!S publicId, text;
        S systemOrPublic, notationName;
        bool reference;

        if (reader.skipSpaces().moveFrontIf('%'))
        {
            reference = true;
            reader.skipSpaces();
        }

        auto name = reader.readAnyName(nameBuffer, localContext);

        if ("\"'".indexOf(reader.skipSpaces().frontIf()) >= 0)
        {
            text = parseQuotedValue();
        }
        else
        {
            parseExternalId(systemOrPublic, publicId, text, false);

            if (!reference && !reader.skipSpaces().empty && reader.front != '>')
            {
                S nData = reader.readAnyName(nameBuffer, localContext);
                if (nData != XmlConst.nData)
                    throw new XmlParserException(localContext.loc,
                        Message.eExpectedStringButString, XmlConst.nData, nData);

                notationName = reader.skipSpaces().readAnyName(nameBuffer, localContext);
            }
        }

        expectChar!(skipSpaceBefore)('>');

        auto parentNode = peekNode();
        XmlNode!S node;
        if (reference)
        {
            if (systemOrPublic.length > 0)
                node = parentNode.appendChild(document.createEntityReference(name,
                        systemOrPublic, publicId, text));
            else
                node = parentNode.appendChild(document.createEntityReference(name, text));
        }
        else
        {
            if (systemOrPublic.length > 0)
                node = parentNode.appendChild(document.createEntity(name,
                        systemOrPublic, publicId, text, notationName));
            else
                node = parentNode.appendChild(document.createEntity(name, text));
        }

        if (useSaxOtherNode && !options.onSaxOtherNode(node))
            parentNode.removeChild(node);
    }

    void parseElementX(ref ParseContext!S tagName)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseElementX.%s", indentString(), tagName.s);
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
        }

        auto name = tagName.s;
        if (options.validate && !isName(name, No.allowEmpty))
            throw new XmlParserException(tagName.loc, Message.eInvalidName, name);

        auto element = cast(XmlElement!S) pushNode(peekNode().appendChild(document.createElement(name)));
        if (useSaxElementBegin)
            options.onSaxElementNodeBegin(element);

        if (!reader.skipSpaces().empty && 
            isNameStartC(reader.front) &&
            !isElementAttributeNameSeparator(reader.front))
        {
            ParseContext!S attributeName;
            do
            {
                parseElementXAttribute(element, attributeName);
            }
            while (!reader.skipSpaces().empty &&
                   isNameStartC(reader.front) &&
                   !isElementAttributeNameSeparator(reader.front));
        }

        if (reader.moveFrontIf('>'))
        {
            if (!reader.empty && !isElementSeparator(reader.front))
                parseElementXText(element);

            expectChar!(0)('<');
            while (!reader.empty && reader.front != '/')
            {
                parseElement();

                if (!reader.empty && !isElementSeparator(reader.front))
                    parseElementXText(element);

                expectChar!(0)('<');
            }
            expectChar!(0)('/');
            parseElementXEnd(tagName.s);
        }
        else
        {
            expectChar!(0)('/');
            expectChar!(0)('>');
            auto parentElement = cast(XmlElement!S) popNode();
            if (useSaxElementEnd && !options.onSaxElementNodeEnd(parentElement))
                peekNode().removeChild(parentElement);
        }
    }

    void parseElementXAttribute(XmlNode!S parentNode, ref ParseContext!S contextName)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writef;

            writef("%sparseElementXAttribute: ", indentString());
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
        }

        // Name
        auto name = reader.readElementXAttributeName(nameBuffer, contextName);
        if (options.validate)
        {
            if (!isName(name, No.allowEmpty))
                throw new XmlParserException(contextName.loc, Message.eInvalidName, name);
            if (parentNode.findAttribute(name))
                throw new XmlParserException(contextName.loc, Message.eAttributeDuplicated, name);
        }

        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("'%s'", name);
        }

        expectChar!(skipSpaceBefore | skipSpaceAfter)('=');

        // Value
        XmlString!S text = parseQuotedValue();

        auto attribute = document.createAttribute(name, text);
        parentNode.appendAttribute(attribute);
        if (useSaxAttribute && !options.onSaxAttributeNode(attribute))
            parentNode.removeAttribute(attribute);
    }

    void parseElementXEnd(S beginTagName)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseElementXEnd.%s", indentString(), beginTagName);
        }

        ParseContext!S endTagName;
        if (reader.readElementXName(nameBuffer, endTagName) != beginTagName)
            throw new XmlParserException(endTagName.loc, Message.eExpectedEndName, beginTagName, endTagName.s);
        expectChar!(skipSpaceBefore)('>');

        auto element = cast(XmlElement!S) popNode();
        if (useSaxElementEnd && !options.onSaxElementNodeEnd(element))
            peekNode().removeChild(element);
    }

    void parseElementXText(XmlNode!S parentNode)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writef;

            writef("%sparseElementXText: ", indentString());
        }

        XmlString!S text;
        bool allWhitespaces;
        reader.readElementXText(textBuffer, text, allWhitespaces);

        debug (traceXmlParser)
        {
            import std.stdio : writeln, writefln;

            if (allWhitespaces)
                writeln("");
            else
                writefln("'%s'", text.toString().leftStringIndicator(30));
        }

        XmlNode!S node;
        if (allWhitespaces)
        {
            if (options.preserveWhitespace)
                node = parentNode.appendChild(document.createSignificantWhitespace(text.value));
            //else
            //    node = parentNode.appendChild(document.createWhitespace(text.value));        
        }
        else
            node = parentNode.appendChild(document.createText(text));

        if (useSaxOtherNode && !options.onSaxOtherNode(node))
            parentNode.removeChild(node);
    }

    void parseExternalId(ref S systemOrPublic, ref XmlString!S publicId,
        ref XmlString!S text, bool optionalText)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseExternalId", indentString());
        }

        ParseContext!S localContext;

        systemOrPublic = reader.skipSpaces().readAnyName(nameBuffer, localContext);
        reader.skipSpaces();

        if (systemOrPublic == XmlConst.system)
            text = parseQuotedValue();
        else if (systemOrPublic == XmlConst.public_)
        {
            publicId = parseQuotedValue();
            reader.skipSpaces();

            if (!optionalText || (!reader.empty && reader.front != '>'))
                text = parseQuotedValue();
        }
        else
            throw new XmlParserException(localContext.loc, Message.eExpectedOneOfStringsButString,
                    XmlConst.public_ ~ " or " ~ XmlConst.system, systemOrPublic);
    }

    void parseNotation(ref ParseContext!S tagName)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseNotation.%s", indentString(), tagName.s);
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
        }

        ParseContext!S localContext;
        XmlString!S publicId, text;
        S systemOrPublic;

        auto name = reader.skipSpaces().readAnyName(nameBuffer, localContext);

        parseExternalId(systemOrPublic, publicId, text, true);

        expectChar!(skipSpaceBefore)('>');

        auto parentNode = peekNode();
        auto node = parentNode.appendChild(document.createNotation(name, systemOrPublic, publicId, text));
        if (useSaxOtherNode && !options.onSaxOtherNode(node))
            parentNode.removeChild(node);
    }

    void parseProcessingInstruction(ref ParseContext!S tagName)
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseProcessingInstruction.%s", indentString(), tagName.s);
            ++nodeIndent;
            scope (exit)
                --nodeIndent;
        }

        // Name
        auto name = tagName.s;
        if (options.validate && !isName(name, No.allowEmpty))
            throw new XmlParserException(tagName.loc, Message.eInvalidName, name);

        if (!reader.readUntilAdv!true(textBuffer, "?>"))
        {
            if (reader.empty)
                throw new XmlParserException(Message.eExpectedStringButEos, "?>");
            else
                throw new XmlParserException(reader.sourceLoc, Message.eExpectedStringButNotFound, "?>");
        }

        auto text = textBuffer.dropBack(2).toStringAndClear();

        auto parentNode = peekNode();
        auto node = parentNode.appendChild(document.createProcessingInstruction(name, text));
        if (useSaxOtherNode && !options.onSaxOtherNode(node))
            parentNode.removeChild(node);
    }

    XmlString!S parseQuotedValue()
    {
        debug (traceXmlParser)
        {
            import std.stdio : writef;

            writef("%sparseQuotedValue: ", indentString());
        }

        auto q = expectChar!(0)("\"'");
        if (!reader.readUntilAdv!false(textBuffer, q, false))
            expectChar!(0)(q);

        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            auto s = textBuffer.toString();
            writefln("'%s'", s.leftStringIndicator(30));
        }

        return textBuffer.toXmlStringAndClear();
    }

    void parseSpaces()
    {
        debug (traceXmlParser)
        {
            import std.stdio : writefln;

            writefln("%sparseSpaces", indentString());
        }

        auto s = reader.readSpaces(asIsBuffer);
        if (options.preserveWhitespace)
        {
            if (nodeStack.length == 1)
            {
                auto node = document.appendChild(document.createWhitespace(s));
                if (useSaxOtherNode && !options.onSaxOtherNode(node))
                    document.removeChild(node);
            }
            else
            {
                auto parentNode = peekNode();
                auto node = parentNode.appendChild(document.createSignificantWhitespace(s));        
                if (useSaxOtherNode && !options.onSaxOtherNode(node))
                    parentNode.removeChild(node);
            }
        }
    }

public:
    @disable this();

    this(XmlDocument!S aDocument, XmlReader!S aReader)
    {
        document = aDocument;
        reader = aReader;
        options = aDocument.parseOptions;

        asIsBuffer = new XmlBuffer!(S, false);
        nameBuffer = new XmlBuffer!(S, false);
        textBuffer = new XmlBuffer!(S, true);

        nodeStack.reserve(defaultXmlLevels);
        pushNode(document);
    }

    XmlDocument!S parse()
    {
        debug (traceXmlParser)
        {
            import std.stdio : writeln;

            writeln("parse");
        }

        initParser();

        try
        {
            while (!reader.empty)
            {
                if (isSpace(reader.front))
                {
                    if (nodeStack.length == 1)
                        reader.skipSpaces();
                    else
                        parseSpaces();
                    if (reader.empty)
                        break;
                }
                expectChar!(0)('<');
                parseElement();
            }
        }
        catch (Exception e)
        {
            if (reader is null || isClassType!XmlParserException(e))
                throw e;
            else
                throw new XmlParserException(reader.sourceLoc, e.msg, e);
        }

        assert(nodeStack.length > 0);

        if (nodeStack.length > 1)
            throw new XmlParserException(Message.eEos);

        return document;
    }
}

unittest  // XmlParser 
{
    if (outputXmlTraceProgress)
    {
        import std.stdio : writeln;

        writeln("unittest XmlParser");
    }

    static immutable string xml = q"XML
    <?xml version="1.0" encoding="UTF-8"?>
    <root>
        <withAttributeOnly att1='' att2=""/>
        <withAttributeOnly2 att1="1" att2="abc"/>
        <attributeWithNP xmlns:myns="something"/>
        <withAttributeAndChild att1="&lt;&gt;&amp;&apos;&quot;" att2='with double quote ""'>
            <child/>
            <child></child>
        </withAttributeAndChild>
        <childWithText>abcd</childWithText>
        <childWithText2>
            line1
            line2
        </childWithText2>
        <myNS:nodeWithNP/>
        <!-- This is a -- comment -->
        <![CDATA[ dataSection! ]]>
    </root>
XML";

    auto doc = new XmlDocument!string().load(xml);
}

unittest  // XmlParser.DOCTYPE
{
    if (outputXmlTraceProgress)
    {
        import std.stdio : writeln;

        writeln("unittest XmlParser.DOCTYPE");
    }

    static immutable string xml = q"XML
    <!DOCTYPE myDoc SYSTEM "http://myurl.net/folder" [
        <!ELEMENT anyElement ANY>
        <!ENTITY replaceText "replacement text">
        <!ATTLIST requireDataFoo foo CDATA #REQUIRED>
    ]>
XML";

    auto doc = new XmlDocument!string().load(xml);
}

unittest  // XmlParser.navigation 
{
    import std.conv : to;
    import std.typecons : No, Yes;

    if (outputXmlTraceProgress)
    {
        import std.stdio : writeln;

        writeln("unittest XmlParser.navigation");
    }

    static immutable string xml = q"XML
    <?xml version="1.0" encoding="UTF-8"?>
    <root>
        <withAttributeOnly att=""/>
        <withAttributeOnly2 att1="1" att2="abc"/>
        <attributeWithNP xmlns:myns="something"/>
        <withAttributeAndChild att1="&lt;&gt;&amp;&apos;&quot;" att2='with double quote ""'>
            <child/>
            <child></child>
        </withAttributeAndChild>
        <childWithText>abcd</childWithText>
        <childWithText2>line &amp; Text</childWithText2>
        <myNS:nodeWithNP/>
        <!-- This is a -- comment -->
        <![CDATA[ dataSection! ]]>
    </root>
XML";

    auto doc = new XmlDocument!string().load(xml);

    debug (traceXmlParser)
    {
        import std.stdio : writeln;

        writeln("\nunittest XmlParser - navigation(start walk)");

        writeln("check doc.documentDeclaration");
    }

    assert(doc.documentDeclaration !is null);
    assert(doc.documentDeclaration.innerText = "version=\"1.0\" encoding=\"UTF-8\"");

    debug (traceXmlParser)
    {
        import std.stdio : writeln;

        writeln("check doc.documentElement");
    }

    assert(doc.documentElement !is null);
    assert(doc.documentElement.nodeType == XmlNodeType.element);
    assert(doc.documentElement.name == "root", doc.documentElement.name);
    assert(doc.documentElement.localName == "root", doc.documentElement.localName);

    XmlNodeList!string L = void;

    debug (traceXmlParser)
    {
        import std.stdio : writeln;

        writeln("check doc.documentElement.getChildNodes(deep=true)");
    }

    L = doc.documentElement.getChildNodes(null, Yes.deep);

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "withAttributeOnly", L.front.name);
    assert(L.front.localName == "withAttributeOnly", L.front.localName);
    assert(L.front.hasAttributes);
    assert(!L.front.hasChildNodes);
    assert(L.front.firstAttribute.name == "att", L.front.firstAttribute.name);
    assert(L.front.firstAttribute.value == "", L.front.firstAttribute.value);
    assert(L.front.firstAttribute is L.front.lastAttribute);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "withAttributeOnly2", L.front.name);
    assert(L.front.localName == "withAttributeOnly2", L.front.localName);
    assert(L.front.hasAttributes);
    assert(!L.front.hasChildNodes);
    assert(L.front.firstAttribute.name == "att1", L.front.firstAttribute.name);
    assert(L.front.firstAttribute.value == "1", L.front.firstAttribute.value);
    assert(L.front.lastAttribute.name == "att2", L.front.lastAttribute.name);
    assert(L.front.lastAttribute.value == "abc", L.front.lastAttribute.value);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "attributeWithNP", L.front.name);
    assert(L.front.localName == "attributeWithNP", L.front.localName);
    assert(L.front.hasAttributes);
    assert(!L.front.hasChildNodes);
    assert(L.front.firstAttribute.name == "xmlns:myns", L.front.firstAttribute.name);
    assert(L.front.firstAttribute.localName == "myns", L.front.firstAttribute.localName);
    assert(L.front.firstAttribute.value == "something", L.front.firstAttribute.value);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "withAttributeAndChild", L.front.name);
    assert(L.front.localName == "withAttributeAndChild", L.front.localName);
    assert(L.front.hasAttributes);
    assert(L.front.hasChildNodes);
    assert(L.front.firstAttribute.name == "att1", L.front.firstAttribute.name);
    assert(L.front.firstAttribute.localName == "att1", L.front.firstAttribute.localName);
    assert(L.front.firstAttribute.value == "<>&'\"", L.front.firstAttribute.value);
    assert(L.front.lastAttribute.name == "att2", L.front.lastAttribute.name);
    assert(L.front.lastAttribute.value == "with double quote \"\"", L.front.lastAttribute.value);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "child", L.front.name);
    assert(L.front.localName == "child", L.front.localName);
    assert(!L.front.hasAttributes);
    assert(!L.front.hasChildNodes);
    assert(L.front.firstAttribute is null);
    assert(L.front.lastAttribute is null);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "child", L.front.name);
    assert(L.front.localName == "child", L.front.localName);
    assert(!L.front.hasAttributes);
    assert(!L.front.hasChildNodes);
    assert(L.front.firstAttribute is null);
    assert(L.front.lastAttribute is null);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();

        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "childWithText", L.front.name);
    assert(L.front.localName == "childWithText", L.front.localName);
    assert(!L.front.hasAttributes);
    assert(L.front.hasChildNodes);
    assert(L.front.innerText == "abcd", L.front.innerText);
    assert(L.front.firstChild.value == "abcd", L.front.firstChild.value);
    L.popFront();
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "childWithText2", L.front.name);
    assert(L.front.localName == "childWithText2", L.front.localName);
    assert(!L.front.hasAttributes);
    assert(L.front.hasChildNodes);
    assert(L.front.innerText == "line & Text", L.front.innerText);
    assert(L.front.firstChild.value == "line & Text", L.front.firstChild.value);
    L.popFront();
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "myNS:nodeWithNP", L.front.name);
    assert(L.front.localName == "nodeWithNP", L.front.localName);
    assert(!L.front.hasAttributes);
    assert(!L.front.hasChildNodes);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.comment, to!string(L.front.nodeType));
    assert(!L.front.hasAttributes);
    assert(!L.front.hasChildNodes);
    assert(L.front.value = " This is a -- comment ", L.front.value);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.cDataSection, to!string(L.front.nodeType));
    assert(!L.front.hasAttributes);
    assert(!L.front.hasChildNodes);
    assert(L.front.value = " dataSection! ", L.front.value);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(L.empty);

    debug (traceXmlParser)
    {        
        import std.stdio : writeln;

        writeln("check doc.documentElement.childNodes()");
    }
    L = doc.documentElement.childNodes();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "withAttributeOnly", L.front.name);
    assert(L.front.localName == "withAttributeOnly", L.front.localName);
    assert(L.front.hasAttributes);
    assert(!L.front.hasChildNodes);
    assert(L.front.firstAttribute.name == "att", L.front.firstAttribute.name);
    assert(L.front.firstAttribute.value == "", L.front.firstAttribute.value);
    assert(L.front.firstAttribute is L.front.lastAttribute);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "withAttributeOnly2", L.front.name);
    assert(L.front.localName == "withAttributeOnly2", L.front.localName);
    assert(L.front.hasAttributes);
    assert(!L.front.hasChildNodes);
    assert(L.front.firstAttribute.name == "att1", L.front.firstAttribute.name);
    assert(L.front.firstAttribute.value == "1", L.front.firstAttribute.value);
    assert(L.front.lastAttribute.name == "att2", L.front.lastAttribute.name);
    assert(L.front.lastAttribute.value == "abc", L.front.lastAttribute.value);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "attributeWithNP", L.front.name);
    assert(L.front.localName == "attributeWithNP", L.front.localName);
    assert(L.front.hasAttributes);
    assert(!L.front.hasChildNodes);
    assert(L.front.firstAttribute.name == "xmlns:myns", L.front.firstAttribute.name);
    assert(L.front.firstAttribute.localName == "myns", L.front.firstAttribute.localName);
    assert(L.front.firstAttribute.value == "something", L.front.firstAttribute.value);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "withAttributeAndChild", L.front.name);
    assert(L.front.localName == "withAttributeAndChild", L.front.localName);
    assert(L.front.hasAttributes);
    assert(L.front.hasChildNodes);
    assert(L.front.firstAttribute.name == "att1", L.front.firstAttribute.name);
    assert(L.front.firstAttribute.localName == "att1", L.front.firstAttribute.localName);
    assert(L.front.firstAttribute.value == "<>&'\"", L.front.firstAttribute.value);
    assert(L.front.lastAttribute.name == "att2", L.front.lastAttribute.name);
    assert(L.front.lastAttribute.value == "with double quote \"\"", L.front.lastAttribute.value);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "childWithText", L.front.name);
    assert(L.front.localName == "childWithText", L.front.localName);
    assert(!L.front.hasAttributes);
    assert(L.front.hasChildNodes);
    assert(L.front.innerText == "abcd", L.front.innerText);
    assert(L.front.firstChild.value == "abcd", L.front.firstChild.value);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "childWithText2", L.front.name);
    assert(L.front.localName == "childWithText2", L.front.localName);
    assert(!L.front.hasAttributes);
    assert(L.front.hasChildNodes);
    assert(L.front.innerText == "line & Text", L.front.innerText);
    assert(L.front.firstChild.value == "line & Text", L.front.firstChild.value);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.element, to!string(L.front.nodeType));
    assert(L.front.name == "myNS:nodeWithNP", L.front.name);
    assert(L.front.localName == "nodeWithNP", L.front.localName);
    assert(!L.front.hasAttributes);
    assert(!L.front.hasChildNodes);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.comment, to!string(L.front.nodeType));
    assert(!L.front.hasAttributes);
    assert(!L.front.hasChildNodes);
    assert(L.front.value = " This is a -- comment ", L.front.value);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(!L.empty);
    assert(L.front.nodeType == XmlNodeType.cDataSection, to!string(L.front.nodeType));
    assert(!L.front.hasAttributes);
    assert(!L.front.hasChildNodes);
    assert(L.front.value = " dataSection! ", L.front.value);
    L.popFront();

    if (doc.parseOptions.preserveWhitespace)
    {
        assert(!L.empty);
        assert(L.front.nodeType == XmlNodeType.whitespace, to!string(L.front.nodeType));
        L.popFront();
    }

    assert(L.empty);
}
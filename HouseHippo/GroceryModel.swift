import Foundation

enum GroceryCategory: String, Codable, CaseIterable {
    case produce = "Produce", meat = "Meat & Seafood", dairy = "Dairy & Eggs", bakery = "Bakery", frozen = "Frozen", pantry = "Pantry", drinks = "Drinks", household = "Household", other = "Other"
    static func suggest(for name: String) -> GroceryCategory {
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        let text = " " + normalized + " "
        // Specific product phrases take precedence over ingredients (e.g. peanut butter, chicken broth).
        let rules: [(GroceryCategory, [String])] = [
            (.household, ["dish soap", "dishwasher", "laundry", "detergent", "paper towels", "toilet paper", "trash bags", "garbage bags", "cat litter", "cat food", "dog food", "toothpaste", "shampoo", "soap", "sponges", "bleach"]),
            (.frozen, ["frozen", "ice cream", "ice cubes", "popsicles"]),
            (.produce, ["bell pepper", "bell peppers", "red pepper", "green pepper", "yellow pepper"]),
            (.pantry, ["peanut butter", "almond butter", "chicken broth", "beef broth", "vegetable broth", "canned", "cans", "tinned", "tomato sauce", "tomato paste", "pasta sauce", "olive oil", "cooking oil", "rice", "pasta", "noodles", "flour", "sugar", "salt", "pepper", "spices", "cereal", "oats", "oatmeal", "crackers", "chips", "honey", "jam", "beans", "lentils", "chickpeas", "nuts", "vinegar", "baking powder", "baking soda", "soup", "salad dressing"]),
            (.dairy, ["milk", "eggs", "egg", "cheese", "yogurt", "yoghurt", "butter", "cream", "half and half", "sour cream", "kefir"]),
            (.meat, ["chicken", "beef", "pork", "turkey", "bacon", "sausage", "ham", "steak", "salmon", "tuna", "fish", "shrimp", "prawns", "ground meat"]),
            (.bakery, ["bread", "bagel", "bagels", "buns", "rolls", "tortillas", "pita", "croissant", "croissants", "muffins"]),
            (.drinks, ["coffee", "tea", "juice", "soda", "water", "seltzer", "lemonade", "kombucha"]),
            (.produce, ["apple", "apples", "banana", "bananas", "orange", "oranges", "lemon", "lemons", "lime", "limes", "grapes", "berries", "strawberries", "blueberries", "raspberries", "avocado", "avocados", "tomato", "tomatoes", "potato", "potatoes", "onion", "onions", "garlic", "carrot", "carrots", "lettuce", "spinach", "kale", "broccoli", "cauliflower", "cucumber", "cucumbers", "zucchini", "squash", "eggplant", "celery", "mushrooms", "peppers", "bell pepper", "cabbage", "asparagus", "peaches", "pears", "melon", "watermelon", "pineapple", "cilantro", "parsley", "basil", "ginger"])
        ]
        return rules.first(where: { _, phrases in phrases.contains { text.contains(" " + $0 + " ") } })?.0 ?? .other
    }
}

struct GroceryItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var checked = false
    var categoryOverride: GroceryCategory?
    var deletedAt: Date?
    var category: GroceryCategory { categoryOverride ?? GroceryCategory.suggest(for: name) }
    static func legacyLine(_ text: String) -> (name: String, checked: Bool)? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("- ") || value.hasPrefix("* ") || value.hasPrefix("• ") { value.removeFirst(2) }
        let checked = value.lowercased().hasPrefix("[x]") || value.hasPrefix("☑") || value.hasPrefix("✅")
        if value.hasPrefix("[ ]") || value.lowercased().hasPrefix("[x]") { value.removeFirst(3) }
        else if value.hasPrefix("☑") || value.hasPrefix("☐") || value.hasPrefix("✅") { value.removeFirst() }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : (value, checked)
    }
}
